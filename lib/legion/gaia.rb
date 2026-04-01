# frozen_string_literal: true

require 'legion/gaia/version'
require 'legion/gaia/tick_history'
require 'legion/gaia/workflow'
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
require 'legion/gaia/proactive_dispatcher'
require 'legion/gaia/bond_registry'
require 'legion/gaia/tracker_persistence'
require 'legion/gaia/router'

module Legion
  module Gaia # rubocop:disable Metrics/ModuleLength
    class << self # rubocop:disable Metrics/ClassLength
      include Legion::Gaia::Logging
      include Legion::Gaia::TeamsAuth

      attr_reader :sensory_buffer, :registry, :channel_registry, :output_router, :session_store,
                  :router_bridge, :agent_bridge, :last_valences, :partner_observations,
                  :tick_history, :tick_count

      def proactive_dispatcher
        @proactive_dispatcher ||= ProactiveDispatcher.new
      end

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
        @tick_unavailable_warned = false
        settings_hash = settings
        settings_hash[:connected] = false if settings_hash

        flush_trackers_on_shutdown
        @router_bridge&.stop
        @agent_bridge&.stop
        @channel_registry&.stop_all
        @sensory_buffer = nil
        @registry = nil
        @channel_registry = nil
        @output_router = nil
        @session_store = nil
        @notification_gate = nil
        @router_bridge = nil
        @agent_bridge = nil
        @partner_observations = nil
        @partner_absence_misses = 0
        @last_valences = nil
        @last_response_at = nil
        @tick_history = nil
        @tick_count = nil
        @started_at = nil

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
          unless @tick_unavailable_warned
            log_warn '[gaia] lex-tick not available, will retry next heartbeat'
            @tick_unavailable_warned = true
          end
          return { error: :no_tick_extension }
        end
        @tick_unavailable_warned = false if @tick_unavailable_warned

        phase_handlers = @registry.phase_handlers

        log_debug "[gaia] heartbeat: signals=#{signals.size} wired_phases=#{phase_handlers.size}"

        observations = @partner_observations.dup
        @partner_observations = []

        result = tick_host.execute_tick(signals: signals, phase_handlers: phase_handlers,
                                        partner_observations: observations)

        @tick_history&.record(result)
        @tick_count = (@tick_count || 0) + 1

        if result.is_a?(Hash) && result[:results]
          valence_result = result[:results][:emotional_evaluation]
          @last_valences = [valence_result[:valence]] if valence_result.is_a?(Hash) && valence_result[:valence]
          tick_host.last_tick_result = result
        end

        check_partner_absence(observations, phase_handlers)

        feed_notification_gate(result)
        @output_router&.process_delayed

        maybe_flush_trackers

        if result.is_a?(Hash) && result[:results]
          process_dream_proactive(result[:results])
          try_dispatch_pending
        end

        result
      end

      def ingest(input_frame)
        return { ingested: false, reason: :not_started } unless started?

        signal = input_frame.to_signal
        @sensory_buffer.push(signal)

        identity = extract_identity(input_frame)
        session = @session_store&.find_or_create(identity: identity || :anonymous)
        @session_store&.touch(session.id, channel_id: input_frame.channel_id) if session

        observe_interlocutor(input_frame, identity) if identity && identity != :anonymous

        { ingested: true, buffer_depth: @sensory_buffer.size, session_id: session&.id }
      end

      def respond(content:, channel_id:, in_reply_to: nil, session_continuity_id: nil, metadata: {})
        @last_response_at = Time.now.utc

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

      def record_advisory_meta(advisory_id:, advisory_types:)
        return unless started?

        @last_response_at = Time.now.utc
        return unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)

        ensure_calibration_runner
        @calibration_runner.record_advisory_meta(advisory_id: advisory_id, advisory_types: advisory_types)
      rescue StandardError => e
        log_warn "record_advisory_meta error: #{e.message}"
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
        @tick_unavailable_warned = false
        @partner_observations = []
        @partner_absence_misses = 0
        @tick_history = TickHistory.new
        @tick_count = 0
        @started_at = Time.now.utc
        @sensory_buffer = SensoryBuffer.new
        @registry = Registry.instance
        @registry.reset!
        @registry.discover
        boot_channels
        boot_agent_bridge
        hydrate_from_apollo_local
      end

      def boot_router
        @started_at = Time.now.utc
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
        @notification_gate = NotificationGate.new(settings: settings || {})
        @output_router = OutputRouter.new(channel_registry: @channel_registry, renderer: renderer,
                                          notification_gate: @notification_gate)

        ChannelAdapter.adapter_classes.each do |klass|
          adapter = klass.from_settings(settings)
          next unless adapter

          adapter.start
          @channel_registry.register(adapter)
        end
      end

      def base_status
        ttl = settings&.dig(:session, :ttl)
        status = {
          started: true,
          mode: @mode,
          buffer_depth: @sensory_buffer&.size || 0,
          active_channels: @channel_registry&.active_channels || [],
          sessions: @session_store&.size || 0,
          tick_count: @tick_count || 0,
          tick_mode: tick_mode_from_host,
          sensory_buffer: {
            depth: @sensory_buffer&.size || 0,
            max_capacity: SensoryBuffer::MAX_BUFFER_SIZE
          },
          sessions_detail: {
            active_count: @session_store&.size || 0,
            ttl: ttl
          },
          uptime_seconds: @started_at ? (Time.now.utc - @started_at).to_i : nil
        }
        status.merge!(registry_status) unless router_mode?
        status
      end

      def tick_mode_from_host
        tick_host = @registry&.tick_host
        return :dormant unless tick_host.respond_to?(:last_tick_result)

        last = tick_host.last_tick_result
        last.is_a?(Hash) ? (last[:mode] || :active) : :dormant
      rescue StandardError => e
        log_debug("[gaia](tick_mode_from_host) #{e.class}: #{e.message}")
        :dormant
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

      def extract_identity(input_frame)
        ctx = input_frame.auth_context
        return nil if ctx.nil? || ctx.empty?

        ctx[:aad_object_id] || ctx[:identity] || ctx[:user_id]
      end

      def observe_interlocutor(input_frame, identity)
        role = BondRegistry.role(identity.to_s)

        observation = {
          identity: identity.to_s,
          bond_role: role,
          channel: input_frame.channel_id,
          content_type: input_frame.content_type,
          content: input_frame.content.to_s,
          content_length: input_frame.content.to_s.length,
          direct_address: input_frame.metadata[:direct_address] || false,
          latency: compute_response_latency,
          timestamp: input_frame.received_at
        }

        @partner_observations ||= []
        @partner_observations.push(observation)

        if role == :partner
          record_interaction_trace(observation)
          evaluate_calibration(observation)
        end
      rescue StandardError => e
        log_warn "observe_interlocutor error: #{e.message}"
      end

      def record_interaction_trace(observation)
        return unless defined?(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)
        runner.store_trace(
          type: :episodic,
          content_payload: {
            interaction_type: observation[:content_type],
            channel: observation[:channel],
            direct_address: observation[:direct_address],
            bond_role: observation[:bond_role]
          },
          domain_tags: ['partner_interaction', observation[:channel].to_s],
          origin: :direct_experience,
          emotional_valence: @last_valences&.dig(0, :urgency).to_s,
          emotional_intensity: 0.5,
          confidence: 0.8
        )
      rescue StandardError => e
        log_debug "Interaction trace error: #{e.message}"
      end

      def apollo_local_store
        return nil unless defined?(Legion::Apollo::Local) && Legion::Apollo::Local.started?

        Legion::Apollo::Local
      rescue StandardError => e
        log_debug "[gaia](apollo_local_store) error #{e.class}: #{e.message}"
        nil
      end

      def evaluate_calibration(observation)
        return unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)

        ensure_calibration_runner
        result = @calibration_runner.update_calibration(observation: observation)
        @last_calibration_deltas = result[:deltas] if result[:success] && result[:deltas]
      rescue StandardError => e
        log_warn "evaluate_calibration error: #{e.message}"
      end

      def ensure_calibration_runner
        return if @calibration_runner

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)
        TrackerPersistence.register_tracker(
          :calibration,
          tracker: runner.send(:calibration_store),
          tags: %w[bond calibration]
        )
        @calibration_runner = runner
      end

      def compute_response_latency
        return nil unless @last_response_at

        (Time.now.utc - @last_response_at).to_f
      end

      def check_partner_absence(observations, phase_handlers)
        has_partner = observations.any? { |o| o[:bond_role] == :partner }

        if has_partner
          @partner_absence_misses = 0
          return
        end

        return unless phase_handlers.key?(:prediction_engine)

        @partner_absence_misses += 1
        inject_absence_valence(@partner_absence_misses)
      rescue StandardError => e
        log_debug "check_partner_absence error: #{e.message}"
      end

      def inject_absence_valence(consecutive_misses)
        valence = absence_valence(consecutive_misses)
        return unless valence

        @last_valences ||= []
        @last_valences.push(valence)
        log_debug "[gaia] partner absence: misses=#{consecutive_misses} " \
                  "importance=#{valence[:importance].round(2)}"
      end

      def absence_valence(consecutive_misses)
        importance = if defined?(Legion::Extensions::Agentic::Affect::Emotion::Helpers::Valence)
                       Legion::Extensions::Agentic::Affect::Emotion::Helpers::Valence
                         .absence_importance(consecutive_misses)
                     else
                       [0.4 + (0.1 * Math.log(consecutive_misses + 1)), 0.7].min
                     end

        { urgency: 0.2, importance: importance, novelty: 0.1, familiarity: 0.8 }
      end

      def feed_notification_gate(result)
        return unless @notification_gate && result.is_a?(Hash) && result[:results]

        if (valence = result.dig(:results, :emotional_evaluation, :valence))
          arousal = compute_arousal(valence)
          @notification_gate.update_behavioral(arousal: arousal) if arousal
        end

        feed_presence_to_gate
      rescue StandardError => e
        log_debug "feed_notification_gate error: #{e.message}"
      end

      def compute_arousal(valence)
        return nil unless valence.is_a?(Hash)

        urgency = valence[:urgency].to_f
        novelty = valence[:novelty].to_f
        importance = valence[:importance].to_f
        ((urgency + novelty + importance) / 3.0).clamp(0.0, 1.0)
      end

      def feed_presence_to_gate
        return unless @notification_gate && @channel_registry

        teams_adapter = @channel_registry.adapter_for(:teams)
        return unless teams_adapter.respond_to?(:last_presence_status)

        status = teams_adapter.last_presence_status
        @notification_gate.update_presence(availability: status) if status
      rescue StandardError => e
        log_debug "feed_presence_to_gate error: #{e.message}"
      end

      def maybe_flush_trackers
        return unless TrackerPersistence.should_flush?

        store = apollo_local_store
        TrackerPersistence.flush_dirty(store: store) if store
      rescue StandardError => e
        log_debug "TrackerPersistence flush error: #{e.message}"
      end

      def flush_trackers_on_shutdown
        store = apollo_local_store
        TrackerPersistence.flush_all(store: store) if store
      rescue StandardError => e
        log_debug "TrackerPersistence shutdown flush error: #{e.message}"
      end

      def hydrate_from_apollo_local
        store = apollo_local_store
        return unless store

        TrackerPersistence.hydrate_all(store: store) if defined?(TrackerPersistence)
        BondRegistry.hydrate_from_apollo(store: store) if defined?(BondRegistry)
      rescue StandardError => e
        log_debug "Apollo Local hydration error on boot: #{e.message}"
      end

      def process_dream_proactive(dream_results)
        return unless dream_results.is_a?(Hash)

        pr = dream_results[:partner_reflection]
        partner_reflection_hash = pr.is_a?(Array) ? pr.find { |r| r.is_a?(Hash) } : pr

        intent = dream_results.dig(:action_selection, :proactive_outreach) ||
                 partner_reflection_hash&.dig(:proactive_suggestion)
        return unless intent

        proactive_dispatcher.queue_intent(intent)
      end

      def try_dispatch_pending
        intents = proactive_dispatcher.drain_pending
        intents.each do |intent|
          result = proactive_dispatcher.dispatch_with_gate(intent)
          unless result[:dispatched]
            proactive_dispatcher.queue_intent(intent)
            break
          end
        end
      rescue StandardError => e
        log_debug "[gaia] proactive dispatch error: #{e.message}"
      end
    end
  end
end
