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
    ABSENCE_SIGNAL_THRESHOLD = 5
    ABSENCE_SIGNAL_COOLDOWN  = 1800
    ABSENCE_SIGNAL_SALIENCE  = 0.75
    ABSENCE_SIGNAL_TEXT      = 'partner absence exceeded expected pattern'

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
        log.info("Legion::Gaia booting mode=#{@mode}")

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

        log.info("Legion::Gaia booted mode=#{@mode} summary=#{boot_summary}")
      end

      def router_mode?
        @mode == :router
      end

      def shutdown
        log.info('Legion::Gaia shutting down')

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
        @last_absence_signal_at = nil
        @last_valences = nil
        @last_response_at = nil
        @tick_history = nil
        @tick_count = nil
        @started_at = nil

        log.info('Legion::Gaia shut down')
      end

      def started?
        @started == true
      end

      def settings
        if Legion.const_defined?('Settings', false)
          Legion::Settings[:gaia] || Legion::Gaia::Settings.default
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
            log.warn('[gaia] lex-tick not available, will retry next heartbeat')
            @tick_unavailable_warned = true
          end
          return { error: :no_tick_extension }
        end
        @tick_unavailable_warned = false if @tick_unavailable_warned

        phase_handlers = @registry.phase_handlers

        log.debug("[gaia] heartbeat signals=#{signals.size} wired_phases=#{phase_handlers.size}")

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
          log_cognitive_markers(result, signals: signals, observations: observations)
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

        log.info(
          "Legion::Gaia ingested frame_id=#{input_frame.id} " \
          "channel=#{input_frame.channel_id} buffer_depth=#{@sensory_buffer.size}"
        )
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

        log.info("Legion::Gaia responding frame_id=#{frame.id} channel=#{channel_id} reply_to=#{in_reply_to}")

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
        log.info(
          "Legion::Gaia recorded advisory metadata advisory_id=#{advisory_id} " \
          "types=#{Array(advisory_types).join(',')}"
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.record_advisory_meta', advisory_id: advisory_id)
      end

      def status
        return { started: false } unless started?

        base_status.merge(router_status)
      end

      private

      def register_routes
        return unless defined?(Legion::API) && Legion::API.respond_to?(:register_library_routes)

        Legion::API.register_library_routes('gaia', Legion::Gaia::Routes)
        log.debug('Legion::Gaia routes registered with API')
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.register_routes')
      end

      def boot_agent
        @tick_unavailable_warned = false
        @partner_observations = []
        @partner_absence_misses = 0
        @last_absence_signal_at = nil
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
        log.info('Legion::Gaia agent mode boot complete')
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
        log.info("Legion::Gaia router mode boot complete allowed_workers=#{allowed.size}")
      end

      def boot_agent_bridge
        return unless settings&.dig(:router, :mode)

        worker_id = settings&.dig(:router, :worker_id)
        return unless worker_id

        @agent_bridge = Router::AgentBridge.new(worker_id: worker_id)
        @agent_bridge.start
        log.info("Legion::Gaia agent bridge booted worker_id=#{worker_id}")
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
          log.info("Legion::Gaia registered channel adapter=#{adapter.channel_id}")
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
        handle_exception(e, level: :debug, operation: 'gaia.tick_mode_from_host')
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
        log.debug(
          "Legion::Gaia observed interlocutor identity=#{identity} " \
          "role=#{role} channel=#{input_frame.channel_id}"
        )

        if role == :partner
          record_interaction_trace(observation)
          evaluate_calibration(observation)
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.observe_interlocutor', identity: identity)
      end

      def record_interaction_trace(observation)
        return unless defined?(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)
        trace_result = runner.store_trace(
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
        log.info("[gaia] memory+ episodic trace=#{trace_result[:trace_id].to_s[0, 8]} " \
                 "channel=#{observation[:channel]} role=#{observation[:bond_role]}")
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.record_interaction_trace',
                            identity: observation[:identity], channel: observation[:channel])
      end

      def apollo_local_store
        return nil unless defined?(Legion::Apollo::Local) && Legion::Apollo::Local.started?

        Legion::Apollo::Local
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.apollo_local_store')
        nil
      end

      def evaluate_calibration(observation)
        return unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)

        ensure_calibration_runner
        result = @calibration_runner.update_calibration(observation: observation)
        @last_calibration_deltas = result[:deltas] if result[:success] && result[:deltas]
        if result[:success] && result[:deltas].is_a?(Hash) && result[:deltas].any?
          log.info("[gaia] calibration identity=#{observation[:identity]} " \
                   "deltas=#{result[:deltas].keys.join(',')}")
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.evaluate_calibration', identity: observation[:identity])
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
        queue_absence_signal_if_needed(@partner_absence_misses, phase_handlers)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.check_partner_absence')
      end

      def inject_absence_valence(consecutive_misses)
        valence = absence_valence(consecutive_misses)
        return unless valence

        @last_valences ||= []
        @last_valences.push(valence)
        log.debug("[gaia] partner absence misses=#{consecutive_misses} " \
                  "importance=#{valence[:importance].round(2)}")
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

      def queue_absence_signal_if_needed(consecutive_misses, phase_handlers)
        return unless @sensory_buffer
        return unless phase_handlers.key?(:action_selection)
        return if consecutive_misses < ABSENCE_SIGNAL_THRESHOLD
        return if recent_absence_signal?
        return unless partner_absence_exceeds_pattern?

        @sensory_buffer.push(
          value: ABSENCE_SIGNAL_TEXT,
          source_type: :partner_absence,
          salience: ABSENCE_SIGNAL_SALIENCE,
          trigger: :proactive_check_in
        )
        @last_absence_signal_at = Time.now.utc
        log.info("[gaia] queued absence signal misses=#{consecutive_misses} " \
                 "salience=#{ABSENCE_SIGNAL_SALIENCE}")
      end

      def recent_absence_signal?
        return false unless @last_absence_signal_at

        (Time.now.utc - @last_absence_signal_at) < ABSENCE_SIGNAL_COOLDOWN
      end

      def partner_absence_exceeds_pattern?
        runner = @registry&.runner_instances&.dig(:Social_Attachment)
        return false unless runner.respond_to?(:reflect_on_bonds)

        result = runner.reflect_on_bonds(tick_results: {}, bond_summary: {})
        result.dig(:partner_bond, :absence_exceeds_pattern) == true
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.partner_absence_exceeds_pattern')
        false
      end

      def feed_notification_gate(result)
        return unless @notification_gate && result.is_a?(Hash) && result[:results]

        if (valence = result.dig(:results, :emotional_evaluation, :valence))
          arousal = compute_arousal(valence)
          @notification_gate.update_behavioral(arousal: arousal) if arousal
          log.debug("[gaia] notification gate behavioral update arousal=#{arousal.round(2)}") if arousal
        end

        feed_presence_to_gate
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.feed_notification_gate')
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
        if status
          @notification_gate.update_presence(availability: status)
          log.debug("[gaia] notification gate presence update status=#{status}")
        end
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.feed_presence_to_gate')
      end

      def maybe_flush_trackers
        return unless TrackerPersistence.should_flush?

        store = apollo_local_store
        TrackerPersistence.flush_dirty(store: store) if store
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.maybe_flush_trackers')
      end

      def flush_trackers_on_shutdown
        store = apollo_local_store
        TrackerPersistence.flush_all(store: store) if store
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.flush_trackers_on_shutdown')
      end

      def hydrate_from_apollo_local
        store = apollo_local_store
        return unless store

        TrackerPersistence.hydrate_all(store: store) if defined?(TrackerPersistence)
        BondRegistry.hydrate_from_apollo(store: store) if defined?(BondRegistry)
        log.info('Legion::Gaia hydrated trackers and bond registry from Apollo Local')
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.hydrate_from_apollo_local')
      end

      def process_dream_proactive(dream_results)
        return unless dream_results.is_a?(Hash)

        pr = dream_results[:partner_reflection]
        partner_reflection_hash = pr.is_a?(Array) ? pr.find { |r| r.is_a?(Hash) } : pr

        intent = dream_results.dig(:action_selection, :proactive_outreach) ||
                 partner_reflection_hash&.dig(:proactive_suggestion)
        return unless intent

        proactive_dispatcher.queue_intent(intent)
        log.info("Legion::Gaia queued proactive intent reason=#{intent.dig(:trigger, :reason)}")
      end

      def try_dispatch_pending
        intents = proactive_dispatcher.drain_pending
        intents.each do |intent|
          result = proactive_dispatcher.dispatch_with_gate(intent)
          unless result[:dispatched]
            proactive_dispatcher.queue_intent(intent)
            log.warn("Legion::Gaia requeued proactive intent reason=#{result[:reason]}")
            break
          end
          log.info("Legion::Gaia dispatched proactive intent reason=#{intent.dig(:trigger, :reason)}")
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.try_dispatch_pending')
      end

      def log_cognitive_markers(result, signals:, observations:)
        return unless result.is_a?(Hash) && result[:results].is_a?(Hash)

        results = result[:results]
        tick_number = result[:tick_number]
        parts = cognitive_marker_base_parts(signals, observations)

        append_memory_markers(parts, results[:memory_retrieval], tick_number, signals)
        append_knowledge_markers(parts, results[:knowledge_retrieval], tick_number)
        append_working_memory_markers(parts, results[:working_memory_integration])
        append_reflection_markers(parts, results[:post_tick_reflection])
        append_action_markers(parts, results[:action_selection], tick_number)

        return if parts.empty?

        log.info("[gaia] cognition tick=#{tick_number} #{parts.join(' ')}")
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.log_cognitive_markers')
      end

      def cognitive_marker_base_parts(signals, observations)
        parts = []
        parts << "signals=#{signals.size}" if signals.any?
        parts << 'idle=true' if signals.empty?

        partner_count = observations.count { |observation| observation[:bond_role] == :partner }
        parts << "partner_observations=#{partner_count}" if partner_count.positive?
        parts << "signal=#{summarize_signals(signals)}" if signals.any?
        parts
      end

      def append_memory_markers(parts, memory, tick_number, signals)
        return unless signals.any? && memory.is_a?(Hash)

        memory_count = memory[:count].to_i
        return unless memory_count.positive?

        parts << "memory=#{memory_count}"
        append_memory_trace_marker(parts, memory)
        log.info("[gaia] memory tick=#{tick_number} #{summarize_memory_hits(memory)}")
      end

      def append_memory_trace_marker(parts, memory)
        top_trace = Array(memory[:traces]).first
        return unless top_trace.is_a?(Hash) && top_trace[:trace_id]

        parts << "trace=#{top_trace[:trace_type]}:#{top_trace[:trace_id].to_s[0, 8]}"
      end

      def append_knowledge_markers(parts, knowledge, tick_number)
        knowledge_count = knowledge_hit_count(knowledge)
        return unless knowledge_count.positive?

        parts << "knowledge=#{knowledge_count}"
        log.info("[gaia] knowledge tick=#{tick_number} #{summarize_knowledge_hits(knowledge)}")
      end

      def knowledge_hit_count(knowledge)
        return 0 unless knowledge.is_a?(Hash)

        count = knowledge[:count].to_i
        return count unless count.zero? && knowledge[:entries].is_a?(Array)

        Array(knowledge[:entries]).size
      end

      def append_working_memory_markers(parts, working)
        return unless working.is_a?(Hash)

        wonders_created = working[:wonders_created].to_i
        parts << "wonders+#{wonders_created}" if wonders_created.positive?

        curiosity = working[:curiosity_intensity]
        parts << "curiosity=#{curiosity.round(2)}" if curiosity.is_a?(Numeric)

        active_wonders = active_wonder_count(working)
        parts << "active_wonders=#{active_wonders}" if active_wonders.to_i.positive?
        append_top_wonder_marker(parts, working, active_wonders)
      end

      def active_wonder_count(working)
        working[:active_count] || working[:active_wonders] || working[:open_wonders]
      end

      def append_top_wonder_marker(parts, working, active_wonders)
        return unless active_wonders.to_i.positive?

        top_wonder = Array(working[:top_wonders]).first
        return unless top_wonder.is_a?(Hash)

        question = top_wonder[:question]
        return unless question.is_a?(String) && !question.empty?

        parts << "wonder=#{truncate_text(question, 48).inspect}"
      end

      def append_reflection_markers(parts, reflection)
        return unless reflection.is_a?(Hash)

        generated = reflection[:reflections_generated].to_i
        parts << "reflections+#{generated}" if generated.positive?

        health = reflection[:cognitive_health]
        parts << "health=#{health}" if health.is_a?(Numeric)

        append_first_reflection_marker(parts, reflection, generated)
      end

      def append_first_reflection_marker(parts, reflection, generated)
        return unless generated.positive?

        first_reflection = Array(reflection[:new_reflections]).first
        return unless first_reflection.is_a?(Hash)

        category = first_reflection[:category]
        observation = first_reflection[:observation]
        parts << "reflection=#{category}:#{truncate_text(observation, 48).inspect}"
      end

      def append_action_markers(parts, action, tick_number)
        return unless action.is_a?(Hash)

        new_intentions = action[:new_intentions].to_i
        parts << "intentions+#{new_intentions}" if new_intentions.positive?
        parts << "active_intentions=#{action[:active_intentions]}" if action[:active_intentions].to_i.positive?
        parts << "drive=#{action[:dominant_drive]}" if action[:dominant_drive]
        append_action_goal_marker(parts, action)

        proactive_reason = action.dig(:proactive_outreach, :trigger, :reason)
        parts << "proactive=#{proactive_reason}" if proactive_reason

        log.info("[gaia] intentions tick=#{tick_number} #{summarize_intentions(action)}")
      end

      def append_action_goal_marker(parts, action)
        goal = action.dig(:current_intention, :goal)
        return unless goal.is_a?(String) && !goal.empty?

        parts << "goal=#{goal.inspect}"
      end

      def summarize_signals(signals)
        Array(signals).first(3).map do |signal|
          next signal.inspect unless signal.is_a?(Hash)

          source = signal[:source_type] || :ambient
          salience = signal[:salience].to_f.round(2)
          text = signal[:value]
          "src=#{source} salience=#{salience} text=#{truncate_text(text, 48).inspect}"
        end.join(' | ')
      end

      def summarize_memory_hits(memory)
        traces = Array(memory[:traces]).first(3)
        "hits=#{traces.map { |trace| summarize_trace_hit(trace) }.join(' ; ')}"
      end

      def summarize_trace_hit(trace)
        return trace.inspect unless trace.is_a?(Hash)

        type = trace[:trace_type] || :unknown
        id = trace[:trace_id].to_s[0, 8]
        strength = trace[:strength]
        payload = trace[:content_payload]
        content = payload.is_a?(Hash) ? payload[:interaction_type] || payload[:channel] : payload
        summary = truncate_text(content, 24)
        "type=#{type} id=#{id} strength=#{strength&.round(2)} content=#{summary.inspect}"
      end

      def summarize_knowledge_hits(knowledge)
        entries = Array(knowledge[:entries] || knowledge[:results]).first(3)
        "hits=#{entries.map { |entry| summarize_knowledge_entry(entry) }.join(' ; ')}"
      end

      def summarize_knowledge_entry(entry)
        return entry.inspect unless entry.is_a?(Hash)

        confidence = entry[:confidence] || entry[:score]
        tags = Array(entry[:tags]).first(2).join(',')
        content = entry[:content] || entry[:text] || entry[:summary] || entry[:title]
        "confidence=#{confidence&.round(2)} tags=#{tags.inspect} content=#{truncate_text(content, 32).inspect}"
      end

      def summarize_intentions(action)
        current = action[:current_intention]
        active = action[:active_intentions]
        goal = current.is_a?(Hash) ? current[:goal] : nil
        drive = current.is_a?(Hash) ? current[:drive] : action[:dominant_drive]
        "active=#{active} drive=#{drive} goal=#{truncate_text(goal, 48).inspect}"
      end

      def truncate_text(value, limit)
        return value unless value.is_a?(String)

        compact = value.strip.gsub(/\s+/, ' ')
        return compact if compact.length <= limit

        "#{compact[0, limit]}..."
      end
    end
  end
end
