# frozen_string_literal: true

require 'legion/gaia/version'
require 'legion/gaia/routes'
require 'legion/gaia/advisory'
require 'legion/gaia/audit_observer'
require 'legion/gaia/settings'
require 'legion/gaia/logging'
require 'legion/gaia/teams_auth'
require 'legion/gaia/runner_host'
require 'legion/gaia/sensory_buffer'
require 'legion/gaia/phase_wiring'
require 'legion/gaia/registry'
require 'legion/gaia/input_frame'
require 'legion/gaia/output_frame'
require 'legion/gaia/channel_adapter'
require 'legion/gaia/channel_registry'
require 'legion/gaia/channel_aware_renderer'
require 'legion/gaia/output_router'
require 'legion/gaia/session_store'
require 'legion/gaia/channels/cli_adapter'
require 'legion/gaia/channels/teams_adapter'
require 'legion/gaia/channels/slack_adapter'
require 'legion/gaia/notification_gate'
require 'legion/gaia/notification_gate/schedule_evaluator'
require 'legion/gaia/proactive'
require 'legion/gaia/offline_handler'
require 'legion/gaia/router'

module Legion
  module Gaia
    class << self
      include Legion::Gaia::Logging
      include Legion::Gaia::TeamsAuth

      attr_reader :sensory_buffer, :registry, :channel_registry, :output_router, :session_store,
                  :router_bridge, :agent_bridge, :last_valences

      def advise(conversation_id:, messages:, caller:)
        Advisory.advise(conversation_id: conversation_id, messages: messages, caller: caller)
      end

      def boot(mode: nil)
        @mode = mode || (settings&.dig(:router, :mode) ? :router : :agent)
        log_info "Legion::Gaia booting (mode: #{@mode})"

        if router_mode?
          boot_router
        else
          boot_agent
        end

        @started = true
        settings_hash = settings
        settings_hash[:connected] = true if settings_hash

        register_routes
        check_teams_auth

        log_info "Legion::Gaia booted (#{@mode}): #{boot_summary}"
      end

      def router_mode?
        @mode == :router
      end

      def shutdown
        log_info 'Legion::Gaia shutting down'

        @started = false
        settings_hash = settings
        settings_hash[:connected] = false if settings_hash

        @router_bridge&.stop
        @agent_bridge&.stop
        @channel_registry&.stop_all
        @sensory_buffer = nil
        @registry = nil
        @channel_registry = nil
        @output_router = nil
        @session_store = nil
        @router_bridge = nil
        @agent_bridge = nil

        log_info 'Legion::Gaia shut down'
      end

      def started?
        @started == true
      end

      def settings
        if Legion.const_defined?('Settings', false)
          Legion::Settings[:gaia]
        else
          Legion::Gaia::Settings.default
        end
      end

      def heartbeat(**)
        return { error: :not_started } unless started?

        signals = @sensory_buffer.drain
        @registry.ensure_wired

        tick_host = @registry.tick_host
        unless tick_host
          log_warn '[gaia] lex-tick not available, will retry next heartbeat'
          return { error: :no_tick_extension }
        end

        phase_handlers = @registry.phase_handlers

        log_debug "[gaia] heartbeat: signals=#{signals.size} wired_phases=#{phase_handlers.size}"

        result = tick_host.execute_tick(signals: signals, phase_handlers: phase_handlers)

        if result.is_a?(Hash) && result[:results]
          valence_result = result[:results][:emotional_evaluation]
          @last_valences = [valence_result[:valence]] if valence_result.is_a?(Hash) && valence_result[:valence]
          tick_host.last_tick_result = result
        end

        result
      end

      def ingest(input_frame)
        return { ingested: false, reason: :not_started } unless started?

        signal = input_frame.to_signal
        @sensory_buffer.push(signal)

        session = @session_store&.find_or_create(identity: input_frame.auth_context[:identity] || :anonymous)
        @session_store&.touch(session.id, channel_id: input_frame.channel_id) if session

        { ingested: true, buffer_depth: @sensory_buffer.size, session_id: session&.id }
      end

      def respond(content:, channel_id:, in_reply_to: nil, session_continuity_id: nil, metadata: {})
        frame = OutputFrame.new(
          content: content,
          channel_id: channel_id,
          in_reply_to: in_reply_to,
          session_continuity_id: session_continuity_id,
          metadata: metadata
        )

        if @agent_bridge&.started?
          @agent_bridge.publish_output(frame)
        else
          @output_router&.route(frame) || { delivered: false, reason: :no_router }
        end
      end

      def status
        return { started: false } unless started?

        base_status.merge(router_status)
      end

      private

      def register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('gaia', Legion::Gaia::Routes)
        Legion::Logging.debug 'Legion::Gaia routes registered with API' if defined?(Legion::Logging)
      rescue StandardError => e
        Legion::Logging.warn "Legion::Gaia route registration failed: #{e.message}" if defined?(Legion::Logging)
      end

      def boot_agent
        @sensory_buffer = SensoryBuffer.new
        @registry = Registry.instance
        @registry.reset!
        @registry.discover
        boot_channels
        boot_agent_bridge
      end

      def boot_router
        boot_channels
        allowed = settings&.dig(:router, :allowed_worker_ids) || []
        @router_bridge = Router::RouterBridge.new(
          channel_registry: @channel_registry,
          allowed_worker_ids: allowed
        )
        @router_bridge.start
      end

      def boot_agent_bridge
        return unless settings&.dig(:router, :mode)

        worker_id = settings&.dig(:router, :worker_id)
        return unless worker_id

        @agent_bridge = Router::AgentBridge.new(worker_id: worker_id)
        @agent_bridge.start
      end

      def boot_summary
        channels = @channel_registry&.size || 0
        return "#{channels} channels, router active" if router_mode?

        wired = @registry&.wired_count || 0
        loaded = @registry&.loaded_count || 0
        total = @registry&.total_count || 0
        "#{wired} phases wired, #{loaded}/#{total} extensions, #{channels} channels"
      end

      def boot_channels
        @channel_registry = ChannelRegistry.new
        @session_store = SessionStore.new(ttl: settings&.dig(:session, :ttl) || 86_400)

        renderer = ChannelAwareRenderer.new(settings: settings || {})
        notification_gate = NotificationGate.new(settings: settings || {})
        @output_router = OutputRouter.new(channel_registry: @channel_registry, renderer: renderer,
                                          notification_gate: notification_gate)

        ChannelAdapter.adapter_classes.each do |klass|
          adapter = klass.from_settings(settings)
          next unless adapter

          adapter.start
          @channel_registry.register(adapter)
        end
      end

      def base_status
        status = {
          started: true,
          mode: @mode,
          buffer_depth: @sensory_buffer&.size || 0,
          active_channels: @channel_registry&.active_channels || [],
          sessions: @session_store&.size || 0
        }
        status.merge!(registry_status) unless router_mode?
        status
      end

      def router_status
        result = {}
        result[:router_routes] = @router_bridge.worker_routing.size if @router_bridge
        result[:agent_bridge] = @agent_bridge&.started? || false if @agent_bridge
        result
      end

      def registry_status
        return {} unless @registry

        {
          extensions_loaded: @registry.loaded_count,
          extensions_total: @registry.total_count,
          wired_phases: @registry.wired_count,
          phase_list: @registry.phase_list
        }
      end
    end
  end
end
