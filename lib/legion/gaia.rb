# frozen_string_literal: true

require 'legion/gaia/version'
require 'legion/gaia/settings'
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

module Legion
  module Gaia
    class << self
      attr_reader :sensory_buffer, :registry, :channel_registry, :output_router, :session_store

      def boot
        log_info 'Legion::Gaia booting'

        @sensory_buffer = SensoryBuffer.new
        @registry = Registry.new
        @registry.discover

        boot_channels

        @started = true
        settings_hash = settings
        settings_hash[:connected] = true if settings_hash

        log_info "Legion::Gaia booted: #{@registry.wired_count} phases wired, " \
                 "#{@registry.loaded_count}/#{@registry.total_count} extensions loaded, " \
                 "#{@channel_registry.size} channels"
      end

      def shutdown
        log_info 'Legion::Gaia shutting down'

        @started = false
        settings_hash = settings
        settings_hash[:connected] = false if settings_hash

        @channel_registry&.stop_all
        @sensory_buffer = nil
        @registry = nil
        @channel_registry = nil
        @output_router = nil
        @session_store = nil

        log_info 'Legion::Gaia shut down'
      end

      def started?
        @started == true
      end

      def settings
        if Legion.const_defined?('Settings')
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
        @output_router&.route(frame) || { delivered: false, reason: :no_router }
      end

      def status
        return { started: false } unless started?

        registry_status.merge(
          started: true,
          buffer_depth: @sensory_buffer&.size || 0,
          active_channels: @channel_registry&.active_channels || [],
          sessions: @session_store&.size || 0
        )
      end

      private

      def boot_channels
        @channel_registry = ChannelRegistry.new
        @session_store = SessionStore.new(ttl: settings&.dig(:session, :ttl) || 86_400)

        renderer = ChannelAwareRenderer.new(settings: settings || {})
        @output_router = OutputRouter.new(channel_registry: @channel_registry, renderer: renderer)

        # Register CLI adapter by default
        return if settings&.dig(:channels, :cli, :enabled) == false

        cli = Channels::CliAdapter.new
        cli.start
        @channel_registry.register(cli)
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

      def log_debug(msg)
        Legion::Logging.debug(msg) if Legion.const_defined?('Logging')
      end

      def log_info(msg)
        Legion::Logging.info(msg) if Legion.const_defined?('Logging')
      end

      def log_warn(msg)
        Legion::Logging.warn(msg) if Legion.const_defined?('Logging')
      end
    end
  end
end
