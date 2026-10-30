# frozen_string_literal: true

require 'singleton'
require 'legion/logging/helper'

module Legion
  module Gaia
    # Outcome behavior shares Registry's scoped state and mutex; it owns no state.
    module RegistryOutcomes
      # Only a producer with a verified outcome and the original exchange/ID can
      # close a prediction or intention. Forming an intention never calls this.
      def record_outcome(identity:, exchange_id:, outcome:, prediction_id: nil, intention_id: nil, actual: nil,
                         verified: false)
        return { status: :unavailable, reason: :unverified_outcome } unless verified == true && identity && exchange_id
        return { status: :skipped, reason: :missing_outcome_id } unless prediction_id || intention_id
        return { status: :unavailable, reason: :ambiguous_outcome_id } if prediction_id && intention_id
        unless actual.is_a?(Hash) && actual[:source] == :human_confirmation &&
               PhaseWiring.comparable_outcome?(value: actual[:observed_outcome])
          return { status: :unavailable, reason: :outcome_evidence_required }
        end

        runners = runner_instances_for(identity: identity)
        @mutex.synchronize do
          results = {}
          if prediction_id
            results[:prediction] = resolve_outcome(kind: :prediction, id: prediction_id, identity: identity,
                                                   exchange_id: exchange_id, outcome: outcome, actual: actual,
                                                   runner: runners[:Prediction_Prediction])
          end
          if intention_id
            results[:intention] = resolve_outcome(kind: :intention, id: intention_id, identity: identity,
                                                  exchange_id: exchange_id, outcome: outcome, actual: actual,
                                                  runner: runners[:Volition_Volition])
          end
          results
        end
      end

      private

      def remember_outcomes(results:, identity:, conversation_id:, exchange_id:)
        return unless identity && exchange_id

        pending = (@pending_outcomes[identity] ||= {})
        correlation = { exchange_id: exchange_id, conversation_id: conversation_id }
        remember_prediction(pending: pending, prediction: results[:prediction_engine], correlation: correlation)
        remember_intentions(pending: pending, actions: results[:action_selection], correlation: correlation)
        pending.shift while pending.size > 200
      end

      def remember_prediction(pending:, prediction:, correlation:)
        return unless PhaseWiring.meaningful_result?(prediction) && prediction[:prediction_id]

        if prediction[:outcome_verifiable] == true
          claim = PhaseWiring.prediction_claim(request: prediction[:prediction_claim])
        end
        pending[[:prediction, prediction[:prediction_id]]] ||= correlation.merge(claim: claim)
      end

      def remember_intentions(pending:, actions:, correlation:)
        return unless PhaseWiring.meaningful_result?(actions)

        Array(actions[:new_intentions]).each do |intention|
          next unless intention.is_a?(Hash) && intention[:intention_id]
          next unless intention[:goal].is_a?(String) && !intention[:goal].strip.empty?

          pending[[:intention, intention[:intention_id]]] ||= correlation.merge(goal: intention[:goal])
        end
      end

      def resolve_outcome(kind:, id:, identity:, exchange_id:, outcome:, actual:, runner:)
        record = @pending_outcomes.dig(identity, [kind, id])
        return { status: :unavailable, reason: :unmatched_outcome } unless record && record[:exchange_id] == exchange_id
        return { status: :skipped, reason: :already_resolved } if record[:resolved]

        if kind == :prediction
          return { status: :unavailable, reason: :unverifiable_prediction } unless record[:claim]
          return { status: :unavailable, reason: :unsupported_outcome } unless %i[correct incorrect
                                                                                  partial].include?(outcome)

          observed = actual[:observed_outcome]
          observed = observed.strip if observed.is_a?(String)
          matches = record[:claim][:expected_outcome] == observed
          return { status: :unavailable, reason: :outcome_comparison_mismatch } if (outcome == :correct) != matches

          unless PhaseWiring.supports_keyword?(runner: runner, method_name: :resolve_prediction, keyword: :identity)
            return { status: :unavailable, reason: :identity_scope_unsupported }
          end

          result = runner.resolve_prediction(prediction_id: id, identity: identity, outcome: outcome, actual: actual)
          record[:resolved] = result[:resolved] == true
        else
          return { status: :unavailable, reason: :not_completed } unless outcome == :completed
          return { status: :unavailable, reason: :missing_handler } unless runner.respond_to?(:complete_intention)

          result = runner.complete_intention(intention_id: id)
          record[:resolved] = result[:status] == :completed
        end
        result.merge(evidence_source: :human_confirmation, observed_outcome: actual[:observed_outcome],
                     prediction_claim: record[:claim], goal: record[:goal])
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.registry.record_outcome', kind: kind)
        { status: :failed, error: e.class.name }
      end
    end
    private_constant :RegistryOutcomes

    class Registry
      include Singleton
      include Legion::Logging::Helper
      include RegistryOutcomes

      attr_reader :runner_instances, :phase_handlers, :discovery

      def initialize
        reset!
      end

      def reset!
        if defined?(PhaseWiring)
          (@scopes || {}).each_key { |identity| PhaseWiring.forget_identity(identity: identity) }
          PhaseWiring.forget_identity(identity: nil)
        end
        @runner_instances = {}
        @phase_handlers = {}
        @phase_state = { signals: {} }
        @discovery = {}
        @scopes = {}
        @capabilities = {}
        @pending_outcomes = {}
        @tick_results = {}
        @discovered = false
        @mutex = Mutex.new
      end

      def discover
        @mutex.synchronize do
          @runner_instances = build_runner_instances(existing: @runner_instances)
          @phase_handlers = PhaseWiring.build_phase_handlers(@runner_instances, phase_state: @phase_state)
          @scopes.each do |identity, scope|
            scope[:runners] = build_runner_instances(existing: scope[:runners], identity: identity)
            scope[:handlers] =
              PhaseWiring.build_phase_handlers(scope[:runners], identity: identity, phase_state: scope[:phase_state])
          end
          @discovery = PhaseWiring.discover_available_extensions
          @discovered = true
        end
        log.info("[gaia:registry] discovered: #{loaded_count}/#{total_count} extensions, #{wired_count} phases wired")
      end

      def rediscover
        discover
        { rediscovered: true, wired_phases: wired_count, phase_list: phase_list }
      end

      def ensure_wired
        discover unless @discovered
      end

      def runner_instances_for(identity:)
        return @runner_instances if identity.nil?

        scope_for(identity: identity)[:runners]
      end

      def phase_handlers_for(identity:)
        return @phase_handlers if identity.nil?

        scope_for(identity: identity)[:handlers]
      end

      def tick_host_for(identity:)
        runner_instances_for(identity: identity)[:Tick_Orchestrator]
      end

      def tick_host
        @runner_instances[:Tick_Orchestrator]
      end

      def supported_optional_phases(identity:, requested:)
        requested = Array(requested).map(&:to_sym)
        unknown = requested - PhaseWiring::OPTIONAL_PHASES
        raise ArgumentError, "unsupported optional phases: #{unknown.join(', ')}" unless unknown.empty?

        host = tick_host_for(identity: identity)
        return [] unless PhaseWiring.supports_keyword?(runner: host, method_name: :execute_tick,
                                                       keyword: :enabled_optional_phases)

        requested
      end

      def capabilities_for(identity:, enabled_optional_phases: [])
        runners = runner_instances_for(identity: identity)
        enabled = supported_optional_phases(identity: identity, requested: enabled_optional_phases)
        observed = @mutex.synchronize { Marshal.load(Marshal.dump(@capabilities[identity] || {})) }
        capabilities = PhaseWiring::PHASE_MAP.to_h do |phase, mappings|
          loaded = PhaseWiring.mappings_for(mappings).all? do |mapping|
            runners[:"#{mapping[:ext]}_#{mapping[:runner]}"].respond_to?(mapping[:fn])
          end
          observation = observed[phase] || {}
          [phase, capability_state(phase: phase, loaded: loaded, observation: observation,
                                   enabled: enabled, requested: enabled_optional_phases)]
        end
        PhaseWiring::PHASE_OWNERS.each do |phase, ownership|
          next if capabilities.key?(phase)

          capabilities[phase] = ownership.merge(ready: false, status: :inactive)
        end
        capabilities
      end

      def record_tick_result(result:, identity:, conversation_id: nil, exchange_id: nil)
        return unless result.is_a?(Hash) && result[:results].is_a?(Hash)

        results = PhaseWiring.normalize_prior_results(result[:results])
        PhaseWiring.capture_tick_results(results, identity: identity, conversation_id: conversation_id)
        now = Time.now.utc
        snapshot = Marshal.load(Marshal.dump(result))
        @mutex.synchronize do
          @tick_results[[identity, conversation_id]] = snapshot
          capabilities = (@capabilities[identity] ||= {})
          results.each do |phase, data|
            record_phase_capability(capabilities: capabilities, phase: phase, data: data, now: now)
          end
          Array(result[:phases_skipped]).each do |phase|
            capabilities[phase] = (capabilities[phase] || {}).merge(
              status: :budget_skipped, meaningful: false, reason: :tick_budget_exhausted, last_observed_at: now
            )
          end
          meta = results[:metacognition]
          if PhaseWiring.meaningful_result?(meta) && meta[:demonstrated_capabilities].is_a?(Hash)
            meta[:demonstrated_capabilities].each do |phase, assessment|
              capabilities[phase][:metacognition] = assessment.dup if capabilities[phase]
            end
          end
          remember_outcomes(results: results, identity: identity, conversation_id: conversation_id,
                            exchange_id: exchange_id)
        end
      end

      def tick_result_for(identity:, conversation_id:)
        @mutex.synchronize do
          result = @tick_results[[identity, conversation_id]]
          result && Marshal.load(Marshal.dump(result))
        end
      end

      def erase_identity(identity:)
        @mutex.synchronize do
          @scopes.delete(identity)
          @capabilities.delete(identity)
          @pending_outcomes.delete(identity)
          @tick_results.delete_if { |(owner, _), _| owner == identity }
        end
        PhaseWiring.forget_identity(identity: identity)
        { erased: true, identity: identity }
      end

      def loaded_count
        @discovery.count { |_, value| value[:loaded] }
      end

      def total_count
        @discovery.size
      end

      def wired_count
        @phase_handlers.size
      end

      def phase_list
        @phase_handlers.keys
      end

      private

      def capability_state(phase:, loaded:, observation:, enabled:, requested:)
        optional = PhaseWiring::OPTIONAL_PHASES.include?(phase)
        active = !optional || enabled.include?(phase)
        reason = if !loaded
                   :missing_handler
                 elsif !active
                   requested.include?(phase) ? :tick_opt_in_unsupported : :not_enabled
                 else
                   observation[:reason] || :not_demonstrated
                 end
        ready = loaded && active && observation[:status] == :completed && observation[:meaningful] == true
        observation.merge(loaded: loaded, ready: ready, reason: ready ? nil : reason,
                          owner: optional ? :optional_tick : :tick)
      end

      def record_phase_capability(capabilities:, phase:, data:, now:)
        return unless data.is_a?(Hash)

        meaningful = PhaseWiring.meaningful_result?(data)
        capabilities[phase] = (capabilities[phase] || {}).merge(
          status: PhaseWiring.phase_status(data), meaningful: meaningful, reason: data[:reason], last_observed_at: now
        )
        return unless meaningful

        outcome = data.slice(:prediction_id, :outcome, :count, :linked, :submitted, :cognitive_health,
                             :reflections_generated, :spotlight, :peripheral, :background, :dropped,
                             :curiosity_intensity, :valence, :arousal, :dominant_drive, :active_intentions)
        outcome[:filtered_count] = data[:filtered].size if data[:filtered].is_a?(Array)
        outcome[:cognitive_health] = data[:cognitive][:health] if data[:cognitive].is_a?(Hash)
        if data[:demonstrated_capabilities].is_a?(Hash)
          outcome[:assessments] = data[:demonstrated_capabilities].transform_values do |assessment|
            assessment.slice(:status, :ready)
          end
        end
        capabilities[phase][:last_meaningful_outcome] = outcome
        capabilities[phase][:last_meaningful_at] = now
      end

      def scope_for(identity:)
        raise ArgumentError, 'identity must not be blank' if identity.to_s.strip.empty?

        @mutex.synchronize do
          @scopes[identity] ||= begin
            runners = build_runner_instances(existing: {}, identity: identity)
            state = { signals: {} }
            { runners: runners, phase_state: state,
              handlers: PhaseWiring.build_phase_handlers(runners, identity: identity, phase_state: state) }
          end
        end
      end

      def build_runner_instances(existing:, identity: nil)
        mappings = [{ ext: :Tick, runner: :Orchestrator }]
        mappings.concat(PhaseWiring::PHASE_MAP.values.flat_map { |value| PhaseWiring.mappings_for(value) })
        mappings.each_with_object({}) do |mapping, instances|
          key = :"#{mapping[:ext]}_#{mapping[:runner]}"
          next if instances.key?(key)

          runner_class = PhaseWiring.resolve_runner_class(mapping[:ext], mapping[:runner])
          next unless runner_class

          original = existing[key]
          instances[key] = if original && original.runner_module.equal?(runner_class)
                             original
                           else
                             RunnerHost.new(runner_class, identity: identity)
                           end
        end
      end
    end
  end
end
