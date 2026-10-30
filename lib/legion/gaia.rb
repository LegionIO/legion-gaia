# frozen_string_literal: true

require 'legion/json'
require 'legion/logging'
require 'legion/settings'
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
require 'legion/gaia/bond_tracker'
require 'legion/gaia/death_protocol'
require 'legion/gaia/behavioral_synapse'
require 'legion/gaia/gut'
require 'legion/gaia/anticipation'
require 'legion/gaia/partner_model'
require 'legion/gaia/disclosure'
require 'legion/gaia/visible_growth'
require 'legion/gaia/tracker_persistence'
require 'legion/gaia/response_attribution'
require 'legion/gaia/calibration_tracker'
require 'legion/gaia/router'

module Legion
  module Gaia # rubocop:disable Metrics/ModuleLength
    ABSENCE_SIGNAL_THRESHOLD = 5
    ABSENCE_SIGNAL_COOLDOWN  = 1800
    ABSENCE_SIGNAL_SALIENCE  = 0.75
    ABSENCE_SIGNAL_TEXT      = 'partner absence exceeded expected pattern'
    ABSENCE_PATTERN_CACHE_TTL = 60

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
        return status if started?
        return { started: false, reason: :shutting_down } if heartbeat_mutex.synchronize { @shutdown_pending }

        @mode = mode || (settings&.dig(:router, :mode) ? :router : :agent)
        @shutting_down = false
        @active_heartbeats = 0
        @quiescing_phase_handlers_cache = nil
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
        deferred = heartbeat_mutex.synchronize do
          return { stopped: false, quiescing: true } if @shutdown_pending

          @shutdown_pending = true
          @shutting_down = true
          @started = false
          @tick_unavailable_warned = false
          wait_for_active_heartbeats
          @deferred_shutdown = @active_heartbeats.to_i.positive?
        end
        return { stopped: false, quiescing: true } if deferred

        finalize_shutdown
      end

      def started?
        @started == true
      end

      def shutting_down?
        heartbeat_mutex.synchronize { @shutting_down == true }
      end

      def settings
        defaults = Legion::Gaia::Settings.default
        loaded = Legion::Settings[:gaia]
        return defaults unless loaded.is_a?(Hash)

        merge_settings_hashes(defaults, loaded)
      end

      def heartbeat(**)
        return { error: :not_started } unless begin_heartbeat

        begin
          tick_execution_mutex.synchronize do
            TrackerPersistence::WRITE_LOCK.synchronize { execute_heartbeat }
          end
        ensure
          finish_heartbeat
        end
      end

      def ingest(input_frame)
        return { ingested: false, reason: :not_started } unless started?

        TrackerPersistence::WRITE_LOCK.synchronize do
          return { ingested: false, reason: :not_started } unless started?

          identity = input_frame.authenticated_identity
          return { ingested: false, reason: :identity_blocked } if identity && identity_lifecycle_blocked?(identity)

          session = @session_store&.find_or_create(identity: identity || :anonymous,
                                                   session_continuity_id: input_frame.session_continuity_id)
          @session_store&.touch(session.id, channel_id: input_frame.channel_id) if session
          conversation_id = input_frame.metadata[:conversation_id] || session&.id
          exchange_id = input_frame.metadata[:exchange_id] || input_frame.id
          duplicate = identity && !mark_pipeline_observation(identity: identity, exchange_id: exchange_id, kind: :input)
          return { ingested: false, reason: :duplicate, session_id: session&.id } if duplicate

          signal = input_frame.to_signal.merge(identity: identity, conversation_id: conversation_id,
                                               exchange_id: exchange_id)
          if identity
            observe_interlocutor(input_frame, identity, conversation_id: conversation_id, exchange_id: exchange_id)
          end
          remember_input_route(input_frame: input_frame, identity: identity)
          outcome = record_confirmed_outcome(input_frame: input_frame, identity: identity)
          @sensory_buffer.push(signal)
          log.info("Legion::Gaia ingested frame_id=#{input_frame.id} buffer_depth=#{@sensory_buffer.size}")
          { ingested: true, buffer_depth: @sensory_buffer.size, session_id: session&.id, exchange_id: exchange_id,
            cognitive_outcome: outcome }.compact
        end
      end

      def respond(content:, channel_id:, in_reply_to: nil, session_continuity_id: nil, metadata: {})
        route = observation_mutex.synchronize { @input_routes&.dig(in_reply_to) }
        if route && route[:channel_id] == channel_id
          if route[:identity] && identity_lifecycle_blocked?(route[:identity])
            return { delivered: false,
                     reason: :identity_blocked }
          end

          metadata = metadata.merge(route[:metadata]).merge(identity: route[:identity])
        end

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

      def erase_attribution!(identity:)
        TrackerPersistence::WRITE_LOCK.synchronize do
          result = ResponseAttribution.erase_partner!(identity: identity, store: apollo_local_store)
          return result unless result.is_a?(Hash) && result[:erased]

          @calibration_runners&.delete(identity.to_s)
          TrackerPersistence.unregister_tracker(name: [:calibration, identity.to_s])
          @sensory_buffer&.erase_identity(identity: identity)
          @notification_gate&.erase_identity(identity: identity)
          clear_identity_context(identity: identity.to_s)
          result
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.erase_attribution', identity: identity)
        { erased: false, durable: false, identity: identity, reason: :erase_failed }
      end

      def record_advisory_meta(advisory_id:, identity:, advisory_types:, applied:)
        return { recorded: false, reason: :not_started } unless started?

        runner = calibration_runner_for(identity: identity)
        return { recorded: false, reason: :scoped_calibration_unavailable } unless runner

        result = runner.record_advisory_meta(advisory_id: advisory_id, identity: identity,
                                             advisory_types: advisory_types, applied: applied)
        { recorded: result.is_a?(Hash) && result[:success] == true }
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.record_advisory_meta', advisory_id: advisory_id)
        { recorded: false, reason: :calibration_failed }
      end

      def record_response_applied(advisory_id:, identity:, applied:)
        return { recorded: false, reason: :not_started } unless started?
        return { recorded: false, reason: :unattributed_identity } if identity.to_s.strip.empty?
        return { recorded: false, reason: :identity_blocked } if identity_lifecycle_blocked?(identity.to_s)

        TrackerPersistence::WRITE_LOCK.synchronize do
          result = ResponseAttribution.record_applied(advisory_id: advisory_id, identity: identity,
                                                      applied: applied, store: apollo_local_store)
          if result[:recorded]
            receipt = result[:receipt]
            types = applied_advisory_types(receipt)
            record_advisory_meta(advisory_id: advisory_id, identity: identity, advisory_types: types, applied: receipt)
          end
          result
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.record_response_applied', advisory_id: advisory_id)
        { recorded: false, reason: :receipt_failed }
      end

      def status(identity: nil)
        return { started: false } unless started?

        base_status.merge(router_status).merge(
          persistence_ready: @persistence_ready == true,
          capabilities: @registry&.capabilities_for(identity: identity,
                                                    enabled_optional_phases: settings.dig(
                                                      :tick, :enabled_optional_phases
                                                    ) || [])
        )
      end

      def drain_growth_frames(identity:, conversation_id: nil)
        return [] if identity.to_s.strip.empty? || identity_lifecycle_blocked?(identity.to_s)

        observation_mutex.synchronize do
          (@pending_growth_frames || {}).delete([identity.to_s, conversation_id&.to_s]) || []
        end
      end

      def tick_result_for(identity:, conversation_id:)
        return nil unless started? && @registry
        return nil if identity.to_s.strip.empty? || identity_lifecycle_blocked?(identity.to_s)

        @registry.tick_result_for(identity: identity, conversation_id: conversation_id)
      end

      def calibration_runner_for(identity:, create: true)
        return nil if identity.to_s.strip.empty? || identity_lifecycle_blocked?(identity.to_s)
        return nil unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)

        TrackerPersistence::WRITE_LOCK.synchronize do
          @calibration_runners ||= {}
          return @calibration_runners[identity.to_s] if @calibration_runners.key?(identity.to_s)
          return nil unless create

          runner = RunnerHost.new(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)
          scoped = runner.method(:record_advisory_meta).parameters.any? do |kind, name|
            %i[key keyreq].include?(kind) && name == :identity
          end
          return nil unless scoped

          tracker = CalibrationTracker.new(identity: identity,
                                           tracker: runner.send(
                                             :calibration_store, identity: identity
                                           ))
          store = apollo_local_store
          return nil unless store && tracker.from_apollo(store: store)

          TrackerPersistence.register_tracker([:calibration, identity.to_s], tracker: tracker,
                                                                             tags: %w[bond calibration])
          @calibration_runners[identity.to_s] = runner
        end
      end

      def observe_from_pipeline(identity:, caller:, exchange_id:)
        return unless started? && caller&.dig(:requested_by, :type)&.to_sym == :human

        TrackerPersistence::WRITE_LOCK.synchronize do
          authenticated = caller.dig(:requested_by, :principal_id) || caller.dig(:requested_by, :identity)
          if authenticated.to_s.empty? || authenticated.to_s != identity.to_s
            return { observed: false,
                     reason: :identity_mismatch }
          end
          return { observed: false, reason: :identity_blocked } if identity_lifecycle_blocked?(identity.to_s)
          return { observed: false, reason: :unattributed_exchange } if exchange_id.to_s.empty?

          observed = mark_pipeline_observation(identity: identity, exchange_id: exchange_id, kind: :pipeline)
          return { observed: false, reason: :duplicate } unless observed

          # This hook reports a returned pipeline result, not another human interaction.
          # InputFrame ingestion owns reinforcement and coldstart observation counting.
          register_interlocutor(identity.to_s)
          { observed: true, identity: identity.to_s, exchange_id: exchange_id }
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.observe_from_pipeline', identity: identity)
        { observed: false, reason: :observation_failed }
      end

      def mark_pipeline_observation(identity:, exchange_id:, kind:)
        return false if exchange_id.nil?

        observation_mutex.synchronize do
          @pipeline_observations ||= {}
          @pipeline_observation_order ||= []
          key = [identity.to_s, exchange_id.to_s]
          return false if @pipeline_observations.dig(key, kind)

          @pipeline_observation_order << key unless @pipeline_observations.key?(key)
          (@pipeline_observations[key] ||= {})[kind] = true
          max_size = settings.dig(:pipeline_observation, :max_tracked) || 10_000
          while @pipeline_observation_order.size > max_size
            @pipeline_observations.delete(@pipeline_observation_order.shift)
          end
          true
        end
      end

      private

      def observation_mutex
        @observation_mutex ||= Mutex.new
      end

      def tick_execution_mutex
        @tick_execution_mutex ||= Mutex.new
      end

      def finalize_shutdown
        TrackerPersistence::WRITE_LOCK.synchronize do
          settings_hash = settings
          settings_hash[:connected] = false if settings_hash
          flush_trackers_on_shutdown
          @router_bridge&.stop
          @agent_bridge&.stop
          @channel_registry&.stop_all
          clear_runtime_state
          heartbeat_mutex.synchronize { @shutdown_pending = false }
        end
        log.info('Legion::Gaia shut down')
        { stopped: true, quiescing: false }
      end

      def clear_runtime_state
        @sensory_buffer = nil
        @registry = nil
        @channel_registry = nil
        @output_router = nil
        @session_store = nil
        @notification_gate = nil
        @router_bridge = nil
        @agent_bridge = nil
        @partner_observations = nil
        @absence_state = {}
        @last_valences = nil
        @calibration_runners = nil
        @pipeline_observations = nil
        @pipeline_observation_order = nil
        @input_routes = nil
        @tick_history = nil
        @tick_count = nil
        @started_at = nil
        @active_heartbeats = 0
        @quiescing_phase_handlers_cache = nil
        @pending_growth_frames = nil
        @deferred_shutdown = false
      end

      def execute_heartbeat
        return { error: :not_started } if shutting_down?

        maybe_flush_trackers
        @registry.ensure_wired
        unless @registry.tick_host
          log.warn('[gaia] lex-tick unavailable; retaining signals') unless @tick_unavailable_warned
          @tick_unavailable_warned = true
          return { error: :no_tick_extension }
        end
        @tick_unavailable_warned = false
        signals = @sensory_buffer.drain_scope
        context = heartbeat_context(signals: signals)
        identity = context[:identity]
        return { error: :identity_blocked } if identity && identity_lifecycle_blocked?(identity)

        host = identity ? @registry.tick_host_for(identity: identity) : @registry.tick_host
        handlers = identity ? @registry.phase_handlers_for(identity: identity) : @registry.phase_handlers
        result = host.execute_tick(signals: signals, phase_handlers: quiescing_phase_handlers(handlers), **context)
        result = record_scoped_tick(result: result, context: context, signals: signals) if result.is_a?(Hash)
        finish_tick_work(result: result, handlers: handlers, identity: identity)
        result
      end

      def heartbeat_context(signals:)
        first = signals.first || {}
        last = signals.last || {}
        identity = first[:identity] || first[:principal_id]
        conversation_id = first[:conversation_id]
        context = {
          identity: identity, conversation_id: conversation_id, exchange_id: last[:exchange_id],
          prediction_request: last.dig(:metadata, :prediction_request),
          partner_observations: drain_partner_observations(identity: identity, conversation_id: conversation_id)
        }
        requested = settings.dig(:tick, :enabled_optional_phases) || []
        unless requested.empty?
          context[:enabled_optional_phases] =
            @registry.supported_optional_phases(identity: identity, requested: requested)
        end
        context
      end

      def record_scoped_tick(result:, context:, signals:)
        scope = context.slice(:identity, :conversation_id, :exchange_id)
        result = result.merge(scope)
        @tick_history.record(result, **scope)
        @tick_count += 1
        @registry.record_tick_result(result: result, **scope)
        if result[:results]
          valence = result.dig(:results, :emotional_evaluation, :valence)
          @last_valences = scope[:identity] ? nil : [valence].compact
          log_cognitive_markers(result, signals: signals, observations: context[:partner_observations])
        end
        result
      end

      def finish_tick_work(result:, handlers:, identity:)
        return if shutting_down?

        unless identity
          check_partner_absence(handlers)
          feed_notification_gate(result)
          process_dream_proactive(result[:results]) if result.is_a?(Hash) && result[:results]
        end
        @output_router&.process_delayed
        maybe_flush_trackers
        try_dispatch_pending
      end

      def remember_input_route(input_frame:, identity:)
        observation_mutex.synchronize do
          @input_routes ||= {}
          @input_routes[input_frame.id] = {
            identity: identity, channel_id: input_frame.channel_id,
            metadata: input_frame.metadata.slice(:conversation_id, :tenant_id, :team_id, :user_id)
          }
          @input_routes.shift while @input_routes.size > SensoryBuffer::MAX_BUFFER_SIZE
        end
      end

      def clear_identity_context(identity:)
        observation_mutex.synchronize do
          @partner_observations&.reject! { |item| item[:identity].to_s == identity }
          @absence_state&.delete(identity)
          @pending_growth_frames&.delete_if { |(owner, _conversation), _frames| owner == identity }
          @input_routes&.delete_if { |_id, route| route[:identity].to_s == identity }
          @pipeline_observations&.delete_if { |(owner, _exchange), _value| owner == identity }
          @pipeline_observation_order&.reject! { |owner, _exchange| owner == identity }
        end
      end

      def record_confirmed_outcome(input_frame:, identity:)
        report = input_frame.metadata[:cognitive_outcome]
        return nil unless report.is_a?(Hash)
        unless identity && input_frame.human_direct? && report[:confirmation].to_s == 'human_observed'
          return { recorded: false, reason: :unconfirmed_outcome }
        end
        return { recorded: false, reason: :outcome_registry_unavailable } unless @registry
        return { recorded: false, reason: :ambiguous_outcome } if [report[:prediction_id],
                                                                   report[:intention_id]].compact.size != 1

        @registry.record_outcome(
          identity: identity, exchange_id: report[:source_exchange_id],
          prediction_id: report[:prediction_id], intention_id: report[:intention_id],
          outcome: report[:outcome], verified: true,
          actual: { source: :human_confirmation, observed_outcome: report[:actual], report_id: input_frame.id }
        )
      end

      def applied_advisory_types(receipt)
        applied_sources_for_receipt(receipt: receipt).map do |source|
          (source[:advisory_type] || :partner_hint).to_sym
        end.uniq
      end

      def applied_sources_for_receipt(receipt:)
        behavior_ids = Array(receipt[:behavioral_synapse_ids]).map(&:to_s)
        trace_ids = Array(receipt[:trace_ids]).map(&:to_s)
        adjustment_ids = Array(receipt[:adjustment_ids]).map(&:to_s)
        selected = receipt[:selected] || {}
        prompt_applied = Array(selected[:adjustments]).any? do |adjustment|
          adjustment[:field].to_s == 'system_prompt' && adjustment_ids.include?(adjustment[:adjustment_id].to_s)
        end
        types = Array(selected[:sources]).filter_map do |source|
          used = case source[:type].to_s
                 when 'synapse' then behavior_ids.include?(source[:source_id].to_s)
                 when 'trace' then trace_ids.include?(source[:source_id].to_s)
                 when 'preference' then prompt_applied
                 else false
                 end
          source if used
        end
        Array(selected[:adjustments]).each do |adjustment|
          next unless adjustment_ids.include?(adjustment[:adjustment_id].to_s)

          types << adjustment
        end
        types
      end

      def drain_partner_observations(identity:, conversation_id:)
        observation_mutex.synchronize do
          selected, remaining = Array(@partner_observations).partition do |observation|
            observation[:identity].to_s == identity.to_s && observation[:conversation_id].to_s == conversation_id.to_s
          end
          @partner_observations = remaining
          selected
        end
      end

      def heartbeat_mutex
        @heartbeat_mutex ||= Mutex.new
      end

      def heartbeat_condition
        @heartbeat_condition ||= ConditionVariable.new
      end

      def begin_heartbeat
        heartbeat_mutex.synchronize do
          return false unless @started == true && @shutting_down != true

          @active_heartbeats = (@active_heartbeats || 0) + 1
          true
        end
      end

      def finish_heartbeat
        finalize = heartbeat_mutex.synchronize do
          @active_heartbeats = [@active_heartbeats.to_i - 1, 0].max
          heartbeat_condition.broadcast if @active_heartbeats.zero?
          @deferred_shutdown && @active_heartbeats.zero?
        end
        finalize_shutdown if finalize
      end

      def wait_for_active_heartbeats
        deadline = Time.now + shutdown_heartbeat_wait_timeout
        next_log_at = Time.now

        while @active_heartbeats.to_i.positive?
          now = Time.now
          break if now >= deadline

          if now >= next_log_at
            log.info("Legion::Gaia waiting for active heartbeats count=#{@active_heartbeats}")
            next_log_at = now + shutdown_heartbeat_wait_log_interval
          end

          heartbeat_condition.wait(heartbeat_mutex, [deadline - now, 0.1].min)
        end

        return unless @active_heartbeats.to_i.positive?

        log.warn(
          'Legion::Gaia shutdown heartbeat wait timed out ' \
          "active_heartbeats=#{@active_heartbeats} timeout_s=#{shutdown_heartbeat_wait_timeout}"
        )
      end

      def shutdown_heartbeat_wait_timeout
        configured_positive_float(settings&.dig(:shutdown, :heartbeat_wait_timeout), 30.0)
      end

      def shutdown_heartbeat_wait_log_interval
        configured_positive_float(settings&.dig(:shutdown, :heartbeat_wait_log_interval), 5.0)
      end

      def configured_positive_float(value, fallback)
        numeric = value.to_f
        numeric.positive? ? numeric : fallback
      end

      def quiescing_phase_handlers(phase_handlers)
        return phase_handlers unless phase_handlers.is_a?(Hash)
        return @quiescing_phase_handlers_cache[:wrapped] if cached_quiescing_handlers?(phase_handlers)

        wrapped = phase_handlers.transform_values do |handler|
          next handler unless handler.respond_to?(:call)

          lambda do |*args, **kwargs, &block|
            if shutting_down?
              { status: :skipped, reason: :gaia_shutting_down }
            else
              handler.call(*args, **kwargs, &block)
            end
          end
        end

        @quiescing_phase_handlers_cache = { source: phase_handlers, wrapped: wrapped }
        wrapped
      end

      def cached_quiescing_handlers?(phase_handlers)
        cache = @quiescing_phase_handlers_cache
        cache.is_a?(Hash) && cache[:source].equal?(phase_handlers)
      end

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
        @absence_state = {}
        @tick_history = TickHistory.new
        @tick_count = 0
        @started_at = Time.now.utc
        @sensory_buffer = SensoryBuffer.new
        @registry = Registry.instance
        @registry.reset!
        @registry.discover
        boot_channels
        boot_agent_bridge
        @calibration_runners = {}
        @pipeline_observations = {}
        @pipeline_observation_order = []
        @pending_growth_frames = {}
        @input_routes = {}
        TrackerPersistence.reset!
        ResponseAttribution.reset!
        TrackerPersistence.register_tracker(:bonds, tracker: BondTracker, tags: %w[bond])
        register_behavioral_synapse_tracker
        TrackerPersistence.register_tracker(:responses, tracker: ResponseAttribution,
                                                        tags: %w[self-knowledge attribution])
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
          notification_gate: notification_gate_status,
          uptime_seconds: @started_at ? (Time.now.utc - @started_at).to_i : nil
        }
        status.merge!(registry_status) unless router_mode?
        status
      end

      def notification_gate_status
        return { schedule: nil, presence: nil, behavioral: nil } unless @notification_gate.respond_to?(:status)

        @notification_gate.status
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.notification_gate_status')
        { schedule: nil, presence: nil, behavioral: nil }
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

      def channel_identity(input_frame)
        ctx = input_frame.auth_context || {}
        ctx[:channel_identity] || ctx[:user_id] || ctx[:identity]
      end

      def identity_lifecycle_blocked?(identity_str)
        return false unless BondRegistry.blocked?(identity: identity_str)

        log.warn("[gaia] private state unavailable for identity=#{identity_str}")
        true
      end

      def observe_interlocutor(input_frame, identity, conversation_id:, exchange_id:)
        identity_str = identity.to_s
        return if identity_lifecycle_blocked?(identity_str) || !input_frame.human_direct?

        register_interlocutor(identity_str)
        prior_entry = BondRegistry.entry(identity: identity_str)
        new_channel = prior_entry && prior_entry[:last_channel] != input_frame.channel_id
        BondRegistry.record_channel(identity_str, channel_id: input_frame.channel_id,
                                                  channel_identity: channel_identity(input_frame))
        BondRegistry.reinforce(identity_str, direct_address: input_frame.metadata[:direct_address] == true,
                                             new_channel: new_channel, multiplier: fetch_imprint_multiplier)

        observation = interlocutor_observation(input_frame: input_frame, identity: identity_str,
                                               conversation_id: conversation_id, exchange_id: exchange_id)
        observation_mutex.synchronize do
          (@partner_observations ||= []) << observation
          @partner_observations.shift while @partner_observations.size > SensoryBuffer::MAX_BUFFER_SIZE
        end
        @absence_state&.delete(identity_str)
        if defined?(Legion::Extensions::Coldstart::Helpers::Bootstrap)
          Legion::Extensions::Coldstart::Helpers::Bootstrap.instance.record_observation
        end
        run_partner_deep_learning(identity_str, observation) if BondRegistry.partner?(identity_str)
        observation
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.observe_interlocutor', identity: identity)
        nil
      end

      def interlocutor_observation(input_frame:, identity:, conversation_id:, exchange_id:)
        metadata = input_frame.metadata
        auth = input_frame.auth_context || {}
        {
          identity: identity, bond_role: BondRegistry.bond(identity),
          channel: input_frame.channel_id, content_type: input_frame.content_type,
          content: input_frame.content.to_s, content_length: input_frame.content.to_s.length,
          direct_address: metadata[:direct_address] == true, timestamp: input_frame.received_at,
          conversation_id: conversation_id, feedback_id: input_frame.id,
          observed_exchange_id: exchange_id, exchange_id: metadata[:response_exchange_id],
          advisory_id: metadata[:advisory_id], in_reply_to: metadata[:in_reply_to],
          corrected_constraint: metadata[:corrected_constraint], domain: metadata[:domain],
          identity_principal_id: input_frame.resolved_principal_id, identity_canonical_name: auth[:canonical_name],
          identity_id: auth[:identity]&.to_s
        }
      end

      def register_interlocutor(identity)
        return unless BondRegistry.bond(identity) == :unknown

        if BondRegistry.partner_entry.nil?
          BondRegistry.register(identity, bond: :partner, priority: :primary, origin: :provisional,
                                          strength: settings.dig(:partner, :prior_strength) || 0.5)
        else
          BondRegistry.register(identity, bond: nil)
        end
      end

      def record_interaction_trace(observation)
        runner = @registry&.runner_instances_for(identity: observation[:identity])&.dig(:Memory_Traces)
        return { stored: false, reason: :memory_unavailable } unless runner.respond_to?(:store_trace)

        emotional_context = interaction_trace_emotional_context(observation)
        trace_result = runner.store_trace(
          type: :episodic,
          content_payload: {
            interaction_type: observation[:content_type],
            channel: observation[:channel],
            direct_address: observation[:direct_address],
            identity: observation[:identity], conversation_id: observation[:conversation_id],
            exchange_id: observation[:observed_exchange_id], content: observation[:content].to_s[0, 4096],
            bond_role: observation[:bond_role]
          }.tap do |payload|
            payload[:emotional_context] = emotional_context if emotional_context
          end,
          domain_tags: ['partner_interaction', observation[:channel].to_s, "partner:#{observation[:identity]}"],
          origin: :direct_experience,
          emotional_valence: interaction_trace_emotional_valence(emotional_context),
          emotional_intensity: interaction_trace_emotional_intensity(emotional_context),
          confidence: 0.8
        )
        log.info("[gaia] memory+ episodic trace=#{trace_result[:trace_id].to_s[0, 8]} " \
                 "channel=#{observation[:channel]} role=#{observation[:bond_role]}")
        trace_result
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
        TrackerPersistence::WRITE_LOCK.synchronize do
          identity = observation[:identity]
          runner = calibration_runner_for(identity: identity)
          detector = runner || @registry&.runner_instances_for(identity: identity)&.dig(:Social_Calibration)
          if detector.respond_to?(:detect_explicit_feedback)
            feedback = detector.detect_explicit_feedback(content: observation[:content].to_s)
            observation = observation.merge(explicit_feedback: feedback[:feedback]) if feedback.is_a?(Hash)
          end
          unless runner || observation[:explicit_feedback] == :negative || observation[:corrected_constraint]
            return { graded: false, reason: :scoped_calibration_unavailable }
          end

          store = apollo_local_store
          claim = ResponseAttribution.claim_feedback(identity: identity, observation: observation, store: store)
          return claim unless claim[:claimed]

          apply_claimed_feedback(runner: runner, receipt: claim[:receipt], observation: observation, store: store)
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.evaluate_calibration', identity: observation[:identity])
        { graded: false, reason: :calibration_failed }
      end

      def apply_claimed_feedback(runner:, receipt:, observation:, store:)
        identity = receipt[:identity]
        if observation[:explicit_feedback] == :negative || observation[:corrected_constraint]
          record_correction_trace(identity: identity, applied: receipt, observation: observation)
        end
        unless runner
          return ResponseAttribution.complete_feedback(
            identity: identity, advisory_id: receipt[:advisory_id], feedback_id: observation[:feedback_id], store: store
          ).merge(graded: false, reason: :scoped_calibration_unavailable)
        end

        runner.record_advisory_meta(advisory_id: receipt[:advisory_id], identity: identity,
                                    advisory_types: applied_advisory_types(receipt), applied: receipt)
        correlation = receipt.slice(:advisory_id, :exchange_id, :conversation_id)
        result = runner.update_calibration(identity: identity, observation: observation.merge(correlation))
        unless result.is_a?(Hash) && result[:reaction_score] && result.dig(:applied,
                                                                           :advisory_id) == receipt[:advisory_id]
          return { graded: false, reason: :unmatched_calibration, advisory_id: receipt[:advisory_id] }
        end

        grade_behavioral_synapses(calibration_result: result, receipt: receipt)
        unless TrackerPersistence.flush_dirty(store: store)
          return { graded: true, persisted: false, reason: :learning_flush_failed, advisory_id: receipt[:advisory_id] }
        end

        ResponseAttribution.complete_feedback(identity: identity, advisory_id: receipt[:advisory_id],
                                              feedback_id: observation[:feedback_id], store: store)
      end

      def grade_behavioral_synapses(calibration_result:, receipt:)
        outcome = calibration_outcome(calibration_result[:reaction_score].to_f)
        return unless outcome

        identity = receipt[:identity]
        return if identity_lifecycle_blocked?(identity)

        Array(receipt[:behavioral_synapse_ids]).each do |sid|
          grade_single_synapse(sid, outcome: outcome, identity: identity, multiplier: fetch_imprint_multiplier,
                                    conversation_id: receipt[:conversation_id])
        end
      end

      def calibration_outcome(reaction_score)
        if reaction_score >= 0.6
          :success
        elsif reaction_score <= 0.4
          :failure
        end
      end

      def grade_single_synapse(sid, outcome:, identity:, multiplier:, conversation_id:)
        pre_entry = BehavioralSynapse.all_for(identity: identity).find { |entry| entry[:id] == sid }
        old_mode  = pre_entry ? BehavioralSynapse::Math.autonomy_mode(pre_entry[:confidence].to_f) : nil

        result = BehavioralSynapse.record_outcome(id: sid, identity: identity, outcome: outcome, multiplier: multiplier)
        return unless result.is_a?(Hash) && result[:found] != false

        surface_pain_frame(result, identity: identity, old_mode: old_mode, conversation_id: conversation_id)
        surface_milestone_frame(result, identity: identity, old_mode: old_mode, conversation_id: conversation_id)
      end

      def surface_pain_frame(result, identity:, old_mode:, conversation_id:)
        return unless result[:status] == 'dampened' && old_mode && old_mode != :observe

        msg = VisibleGrowth.pain_revert_acknowledgment(identity: identity, domain: result[:domain].to_s)
        enqueue_growth_frame(message: msg, identity: identity, conversation_id: conversation_id) if msg
      end

      def surface_milestone_frame(result, identity:, old_mode:, conversation_id:)
        new_mode = BehavioralSynapse::Math.autonomy_mode(result[:confidence].to_f)
        return unless old_mode && new_mode != old_mode && result[:status] == 'active'

        msg = VisibleGrowth.milestone_acknowledgment(
          identity: identity.to_s,
          domain: result[:domain].to_s,
          new_mode: new_mode,
          old_mode: old_mode
        )
        enqueue_growth_frame(message: msg, identity: identity, conversation_id: conversation_id) if msg
      end

      def run_partner_deep_learning(identity_str, observation)
        record_interaction_trace(observation)
        evaluate_calibration(observation)
        update_preference_profile(identity_str, observation)
      end

      def update_preference_profile(identity_str, observation)
        return unless defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)

        Legion::Extensions::Mesh::Helpers::PreferenceProfile.update_from_observation(
          owner_id: identity_str, signals: observation
        )
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.update_preference_profile', identity: identity_str)
      end

      def record_correction_trace(identity:, applied:, observation:)
        runner = @registry&.runner_instances_for(identity: identity)&.dig(:Memory_Traces)
        return { stored: false, reason: :memory_unavailable } unless runner.respond_to?(:store_trace)

        sources = Array(applied.dig(:selected, :sources))
        domain = observation[:domain] || sources.filter_map { |source| source[:domain] if source.is_a?(Hash) }.first
        negative_feedback = observation[:explicit_feedback] == :negative
        result = runner.store_trace(
          type: :episodic,
          content_payload: {
            correction_type: negative_feedback ? :explicit_negative_feedback : :explicit_correction,
            identity: identity,
            applied_synapse_ids: Array(applied[:behavioral_synapse_ids]), advisory_id: applied[:advisory_id],
            conversation_id: applied[:conversation_id], exchange_id: applied[:exchange_id],
            feedback_id: observation[:feedback_id], corrected_constraint: observation[:corrected_constraint],
            domain: domain, content: observation[:content].to_s[0, 4096],
            channel: observation[:channel], content_type: observation[:content_type]
          },
          domain_tags: ['correction', "partner:#{identity}"], origin: :direct_experience,
          emotional_valence: -0.5, emotional_intensity: 0.6, confidence: 0.9
        )
        { stored: !result[:trace_id].nil?, trace_id: result[:trace_id] }
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.record_correction_trace', identity: identity)
        { stored: false, reason: :correction_failed }
      end

      def fetch_imprint_multiplier
        # Soft-dep on lex-coldstart; returns settings default if unavailable
        return 1.0 unless defined?(Legion::Extensions::Coldstart) && Legion::Extensions::Coldstart.connected?

        runner = @registry&.runner_instances&.dig(:Coldstart)
        return settings&.dig(:bonds, :imprint_multiplier) || 3.0 unless runner.respond_to?(:imprint_active?)

        runner.imprint_active? ? (runner.current_multiplier || 3.0) : 1.0
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.fetch_imprint_multiplier')
        settings&.dig(:bonds, :imprint_multiplier) || 3.0
      end

      def interaction_trace_emotional_context(observation)
        tick = tick_result_for(identity: observation[:identity], conversation_id: observation[:conversation_id])
        context = tick&.dig(:results, :emotional_evaluation, :valence)
        context.is_a?(Hash) ? context.dup : nil
      end

      def interaction_trace_emotional_valence(emotional_context)
        raw = emotional_context.is_a?(Hash) ? emotional_context[:valence] : emotional_context
        raw.is_a?(Numeric) ? raw.to_f.clamp(-1.0, 1.0) : 0.0
      end

      def interaction_trace_emotional_intensity(emotional_context)
        compute_arousal(emotional_context) || 0.5
      end

      def merge_settings_hashes(base, override)
        return override unless base.is_a?(Hash) && override.is_a?(Hash)

        base.merge(override) do |_key, base_value, override_value|
          merge_settings_hashes(base_value, override_value)
        end
      end

      def check_partner_absence(phase_handlers)
        unless @persistence_ready && phase_handlers.key?(:prediction_engine) && phase_handlers.key?(:action_selection)
          return
        end

        partner = BondRegistry.partner_entry
        return unless partner && !identity_lifecycle_blocked?(partner[:identity])

        identity = partner[:identity]
        state = (@absence_state[identity] ||= { misses: 0 })
        state[:misses] += 1
        return if state[:misses] < ABSENCE_SIGNAL_THRESHOLD
        return if state[:last_signal_at] && Time.now.utc - state[:last_signal_at] < ABSENCE_SIGNAL_COOLDOWN
        return unless partner_absence_exceeds_pattern?(identity: identity, state: state)

        @sensory_buffer.push(
          value: ABSENCE_SIGNAL_TEXT, source_type: :partner_absence, salience: ABSENCE_SIGNAL_SALIENCE,
          identity: identity, exchange_id: SecureRandom.uuid, trigger: :proactive_check_in
        )
        state[:last_signal_at] = Time.now.utc
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.check_partner_absence')
      end

      def partner_absence_exceeds_pattern?(identity:, state:)
        return state[:exceeds] if state[:checked_at] && Time.now.utc - state[:checked_at] < ABSENCE_PATTERN_CACHE_TTL

        runner = @registry&.runner_instances_for(identity: identity)&.dig(:Social_Attachment)
        return false unless runner.respond_to?(:reflect_on_bonds)
        return false unless runner.method(:reflect_on_bonds).parameters.any? do |kind, name|
          %i[key keyreq].include?(kind) && name == :identity
        end

        result = runner.reflect_on_bonds(identity: identity, tick_results: {},
                                         bond_summary: BondRegistry.entry(identity: identity))
        state[:checked_at] = Time.now.utc
        state[:exceeds] =
          result.is_a?(Hash) && result[:success] != false && result.dig(:partner_bond, :absence_exceeds_pattern) == true
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
        store = apollo_local_store
        hydrate_from_apollo_local if store && TrackerPersistence.hydration_due?
        return unless @persistence_ready && TrackerPersistence.should_flush?

        TrackerPersistence.flush_dirty(store: store)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.maybe_flush_trackers')
      end

      def flush_trackers_on_shutdown
        store = apollo_local_store
        TrackerPersistence.flush_all(store: store) if store
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.flush_trackers_on_shutdown')
      end

      def register_behavioral_synapse_tracker
        TrackerPersistence.register_tracker(
          :behavioral_synapse,
          tracker: BehavioralSynapse::Tracker.new,
          tags: %w[self-knowledge behavior]
        )
      end

      def hydrate_from_apollo_local
        store = apollo_local_store
        @persistence_ready = TrackerPersistence.hydrate_all(store: store)
        return false unless @persistence_ready

        BondRegistry.all_bonds.each { |entry| calibration_runner_for(identity: entry[:identity]) }
        DeathProtocol.resume_pending(store: store)
        log.info('Legion::Gaia restored live private state and lifecycle barriers')
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.hydrate_from_apollo_local')
        @persistence_ready = false
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
        intents.each_with_index do |intent, index|
          result = proactive_dispatcher.dispatch_with_gate(intent)
          unless result[:dispatched]
            requeue_proactive_intents(intents[index..], reason: result[:reason])
            break
          end
          log.info("Legion::Gaia dispatched proactive intent reason=#{intent.dig(:trigger, :reason)}")
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.try_dispatch_pending')
      end

      def requeue_proactive_intents(intents, reason:)
        intents.each { |intent| proactive_dispatcher.queue_intent(intent) }
        log.warn("Legion::Gaia requeued proactive intents count=#{intents.size} reason=#{reason}")
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

      def count_marker_value(value)
        return value.size if value.is_a?(Array)
        return 0 unless value.respond_to?(:to_i)

        value.to_i
      end

      def append_action_markers(parts, action, tick_number)
        return unless action.is_a?(Hash)

        new_intentions = count_marker_value(action[:new_intentions])
        parts << "intentions+#{new_intentions}" if new_intentions.positive?
        if count_marker_value(action[:active_intentions]).positive?
          parts << "active_intentions=#{count_marker_value(action[:active_intentions])}"
        end
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

      # Acknowledgments belong only to the human and conversation that earned them.
      def enqueue_growth_frame(message:, identity:, conversation_id:)
        return if message.to_s.empty? || identity.to_s.empty?

        observation_mutex.synchronize do
          @pending_growth_frames ||= {}
          key = [identity.to_s, conversation_id&.to_s]
          (@pending_growth_frames[key] ||= []) << message
        end
      end
    end
  end
end
