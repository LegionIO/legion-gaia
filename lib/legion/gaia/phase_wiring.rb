# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module PhaseWiring # rubocop:disable Metrics/ModuleLength
      extend Legion::Logging::Helper

      PHASE_MAP = {
        sensory_processing: { ext: :Attention, runner: :Attention, fn: :filter_signals },
        emotional_evaluation: { ext: :Emotion, runner: :Valence,       fn: :evaluate_valence },
        memory_retrieval: { ext: :Memory, runner: :Traces, fn: :retrieve_ranked },
        knowledge_retrieval: { ext: :Apollo, runner: :Request, fn: :retrieve },
        identity_entropy_check: { ext: :Identity, runner: :Identity, fn: :check_entropy },
        working_memory_integration: { ext: :Curiosity, runner: :Curiosity, fn: :detect_gaps },
        procedural_check: { ext: :Coldstart, runner: :Coldstart, fn: :coldstart_progress },
        prediction_engine: { ext: :Prediction, runner: :Prediction, fn: :predict },
        mesh_interface: { ext: :Mesh, runner: :Mesh, fn: :mesh_status },
        social_cognition: { ext: :Social, runner: :Social, fn: :update_social },
        theory_of_mind: { ext: :Social, runner: :TheoryOfMind, fn: :update_theory_of_mind },
        gut_instinct: { ext: :Emotion, runner: :Gut, fn: :gut_instinct },
        action_selection: { ext: :Volition, runner: :Volition, fn: :form_intentions },
        memory_consolidation: { ext: :Memory, runner: :Consolidation, fn: :decay_cycle },
        homeostasis_regulation: { ext: :Homeostasis, runner: :Homeostasis, fn: :regulate },
        post_tick_reflection: { ext: :Reflection, runner: :Reflection, fn: :reflect },

        # Dream cycle phases
        memory_audit: { ext: :Memory, runner: :Traces, fn: :retrieve_ranked },
        association_walk: { ext: :Memory, runner: :Consolidation, fn: :hebbian_link },
        contradiction_resolution: { ext: :Conflict, runner: :Conflict, fn: :active_conflicts },
        agenda_formation: { ext: :Curiosity, runner: :Curiosity, fn: :form_agenda },
        consolidation_commit: { ext: :Memory, runner: :Consolidation, fn: :migrate_tier },
        knowledge_promotion: { ext: :Apollo, runner: :Knowledge, fn: :handle_ingest },
        dream_reflection: { ext: :Reflection, runner: :Reflection, fn: :reflect_on_dream },
        partner_reflection: [
          { ext: :Social, runner: :Attachment, fn: :reflect_on_bonds },
          { ext: :Social, runner: :Calibration, fn: :sync_partner_knowledge }
        ],
        dream_narration: { ext: :Narrator, runner: :Narrator, fn: :narrate },

        # Only lex-tick's explicitly opted-in phases belong here.
        metacognition: { ext: :Metacognition, runner: :Metacognition, fn: :introspect },
        global_workspace: { ext: :GlobalWorkspace, runner: :GlobalWorkspace, fn: :run_competition }
      }.freeze

      OPTIONAL_PHASES = %i[global_workspace metacognition].freeze
      MEMORY_METADATA_TAGS = %w[general correction episodic semantic partner_interaction prediction gaia dream_cycle
                                promoted].freeze
      PHASE_OWNERS = {
        curiosity_execution: { owner: :background, reason: :curiosity_actor },
        dream_cycle: { owner: :background, reason: :dream_actor },
        creativity_tick: { owner: :background, reason: :creativity_actor },
        lucid_dream: { owner: :request, reason: :requires_explicit_dream_content },
        epistemic_vigilance: { owner: :request, reason: :requires_real_claim },
        predictive_processing: { owner: :event, reason: :requires_model_and_observation },
        free_energy: { owner: :event, reason: :requires_real_belief },
        default_mode_network: { owner: :background, reason: :idle_thought_actor },
        prospective_memory: { owner: :event, reason: :requires_real_intention },
        inner_speech: { owner: :request, reason: :requires_meaningful_content_consumer },
        global_workspace: { owner: :optional_tick, reason: :explicit_opt_in },
        metacognition: { owner: :optional_tick, reason: :explicit_opt_in }
      }.freeze

      PHASE_ARGS = {
        sensory_processing: lambda { |ctx|
          { signals: ctx[:signals] || [],
            active_wonders: ctx.dig(:prior_results, :agenda_formation, :agenda) || [] }
        },
        emotional_evaluation: lambda { |ctx|
          signal = decision_signal(ctx) || {}
          { signal: signal, source_type: signal[:source_type] || :ambient,
            human_observations: partner_observations_from(ctx) }
        },
        memory_retrieval: ->(ctx) { { signals: decision_signals(ctx) } },
        knowledge_retrieval: lambda { |ctx|
          signal = decision_signal(ctx)
          return { skip: true, reason: :no_attended_signal } unless signal

          # Strength is not evidence that memory answers this request. Knowledge
          # retrieval remains available even when a strong trace was recalled.
          { text: signal[:value] || signal[:content],
            limit: knowledge_setting(:retrieval_limit, 5),
            min_confidence: knowledge_setting(:retrieval_min_confidence, 0.3),
            tags: signal[:tags],
            requesting_principal_id: signal[:principal_id] }
        },
        identity_entropy_check: ->(_ctx) { {} },
        procedural_check: ->(_ctx) { {} },
        prediction_engine: ->(ctx) { prediction_args(ctx) },
        mesh_interface: ->(_ctx) { {} },
        social_cognition: lambda { |ctx|
          if Array(ctx[:signals]).empty? && partner_observations_from(ctx).empty?
            return { skip: true,
                     reason: :idle_no_signals }
          end

          { tick_results: ctx[:prior_results] || {},
            human_observations: partner_observations_from(ctx) }
        },
        theory_of_mind: lambda { |ctx|
          if Array(ctx[:signals]).empty? && partner_observations_from(ctx).empty?
            return { skip: true,
                     reason: :idle_no_signals }
          end

          { tick_results: ctx[:prior_results] || {},
            human_observations: partner_observations_from(ctx) }
        },
        gut_instinct: ->(ctx) { { valences: ctx[:valences] || [] } },
        action_selection: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {},
            cognitive_state: build_cognitive_state(ctx[:prior_results] || {}, identity: ctx[:identity],
                                                                              conversation_id: ctx[:conversation_id],
                                                                              signals: decision_signals(ctx)),
            bond_state: bond_state_from(ctx) }
        },
        working_memory_integration: ->(ctx) { { prior_results: working_memory_inputs(ctx) } },
        memory_consolidation: ->(_ctx) { { skip: true, status: :deferred, reason: :background_decay_actor } },
        homeostasis_regulation: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        post_tick_reflection: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        memory_audit: ->(ctx) { { signals: decision_signals(ctx) } },
        association_walk: ->(ctx) { association_args(ctx) },
        contradiction_resolution: ->(_ctx) { {} },
        agenda_formation: ->(_ctx) { {} },
        consolidation_commit: ->(_ctx) { { skip: true, status: :deferred, reason: :background_consolidation_actor } },
        knowledge_promotion: lambda { |ctx|
          return { skip: true, status: :unavailable, reason: :private_promotion_unsupported } if ctx[:identity]

          content = build_promotion_content(ctx[:prior_results] || {})
          return { skip: true } if content.nil?

          { content: content, content_type: :observation, tags: %w[dream_cycle promoted],
            source_agent: 'gaia', source_channel: 'dream_cycle' }
        },
        dream_reflection: ->(ctx) { { dream_results: ctx[:prior_results] || {} } },
        partner_reflection: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {},
            bond_summary: ctx.dig(:prior_results, :dream_reflection) || {} }
        },
        dream_narration: lambda { |ctx|
          return { skip: true, reason: :no_dream_content } unless build_promotion_content(ctx[:prior_results] || {})

          { tick_results: ctx[:prior_results] || {}, cognitive_state: { source: :dream } }
        },

        metacognition: lambda { |ctx|
          results = ctx[:prior_results] || {}
          unless meaningful_result?(results[:post_tick_reflection])
            return { skip: true, status: :deferred,
                     reason: :no_meaningful_reflection }
          end

          { tick_results: results, subsystem_states: demonstrated_capabilities(results) }
        },
        global_workspace: ->(_ctx) { {} }
      }.freeze

      @previous_reflection = {}
      @previous_reflection_mutex = Mutex.new

      module_function

      def previous_reflection(identity: nil, conversation_id: nil)
        @previous_reflection_mutex.synchronize { @previous_reflection[[identity, conversation_id]] || {} }
      end

      def capture_tick_results(results, identity: nil, conversation_id: nil)
        return unless results.is_a?(Hash)

        reflection = normalize_phase_result(results[:post_tick_reflection])
        return unless meaningful_result?(reflection)

        @previous_reflection_mutex.synchronize do
          @previous_reflection[[identity, conversation_id]] = reflection
        end
      end

      def forget_identity(identity:)
        @previous_reflection_mutex.synchronize { @previous_reflection.delete_if { |(owner, _), _| owner == identity } }
      end

      def build_cognitive_state(prior_results, identity: nil, conversation_id: nil, signals: [])
        state = {
          curiosity: extract_curiosity_state(prior_results),
          reflection: extract_reflection_state(identity: identity, conversation_id: conversation_id),
          prediction: extract_prediction_state(prior_results),
          mesh: extract_mesh_state(prior_results),
          trust: extract_trust_state(prior_results),
          emotion: extract_emotion_state(prior_results),
          gut: prior_results[:gut_instinct]
        }
        selection = prior_results.dig(:global_workspace, :broadcast, :content)
        signal = selection.is_a?(Hash) ? selection[:signal] : signals.first
        traces = memory_traces(prior_results[:memory_retrieval])
        selected_trace = selection[:trace] if selection.is_a?(Hash)
        traces = [selected_trace] if selected_trace.is_a?(Hash)
        apply_attended_signal(state: state, signal: signal)
        apply_memory_influence(state: state, traces: traces, selected_trace: selected_trace)
        state.merge(attention: signal, memory: traces, workspace: selection)
      end

      def apply_attended_signal(state:, signal:)
        return unless signal.is_a?(Hash)

        state[:curiosity].merge!(
          top_question: signal[:value] || signal[:content],
          top_domain: signal[:domain] || Array(signal[:tags]).first || :general
        )
        score = signal[:attention_score] || signal[:salience]
        state[:emotion][:arousal] = [state[:emotion][:arousal], score.to_f.clamp(0.0, 1.0)].max if score
      end

      def apply_memory_influence(state:, traces:, selected_trace:)
        if selected_trace.is_a?(Hash)
          payload = selected_trace[:content_payload]
          content = payload.is_a?(Hash) ? payload[:corrected_constraint] || payload[:content] : payload
          state[:curiosity][:top_question] = content if content.is_a?(String)
        end
        corrections = traces.count { |trace| Array(trace[:domain_tags]).map(&:to_s).include?('correction') }
        return unless corrections.positive?

        state[:reflection] = state[:reflection].merge(
          pending_adaptations: corrections,
          recent_severity: :correction,
          health: [state[:reflection].fetch(:health, 1.0), 0.5].min
        )
      end

      def extract_curiosity_state(prior_results)
        wmi = prior_results[:working_memory_integration] || {}
        {
          intensity: wmi[:curiosity_intensity] || 0.0,
          active_count: wmi[:active_count] || 0,
          top_question: wmi.dig(:top_wonders, 0, :question),
          top_domain: :general
        }
      end

      def extract_reflection_state(identity: nil, conversation_id: nil)
        refl = previous_reflection(identity: identity, conversation_id: conversation_id)
        return {} if refl.nil? || refl.empty?

        new_refls = refl[:new_reflections]
        severity = new_refls.is_a?(Array) ? new_refls.last&.dig(:severity) : nil

        {
          health: refl[:cognitive_health] || 1.0,
          pending_adaptations: refl[:reflections_generated] || 0,
          recent_severity: severity
        }
      end

      def extract_prediction_state(prior_results)
        pred = prior_results[:prediction_engine] || {}
        return {} if pred[:status] == :skipped || pred.empty?

        { confidence: pred[:confidence] || 1.0 }
      end

      def extract_mesh_state(prior_results)
        mesh = prior_results[:mesh_interface] || {}
        return {} if mesh[:status] == :skipped || mesh.empty?

        { peer_count: mesh[:online] || mesh[:total] || 0 }
      end

      def extract_trust_state(prior_results)
        social = prior_results[:social_cognition] || {}
        updates = social[:reputation_updates]
        return {} unless updates.is_a?(Array) && !updates.empty?

        composites = updates.filter_map { |u| u[:composite] }
        return {} if composites.empty?

        { avg_composite: composites.sum.to_f / composites.size }
      end

      def extract_emotion_state(prior_results)
        gut = prior_results[:gut_instinct] || {}
        { arousal: gut[:arousal] || 0.0 }
      end

      def knowledge_setting(key, default)
        return default if Legion::Settings[:gaia].nil?

        Legion::Settings[:gaia].dig(:knowledge, key) || default
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.phase_wiring.knowledge_setting', key: key)
        default
      end

      def resolve_runner_class(ext_sym, runner_sym)
        # Check core library namespace first (e.g., Legion::Apollo)
        core = core_library_runner(ext_sym, runner_sym)
        return core if core

        # Then check extensions namespace
        ext_mod = locate_ext_mod(ext_sym)
        return flat_runner(ext_mod, runner_sym) || subdomain_runner(ext_mod, runner_sym) if ext_mod

        deep_agentic_runner(ext_sym, runner_sym)
      end

      def core_library_runner(ext_sym, runner_sym)
        return nil unless Legion.const_defined?(ext_sym, false)

        mod = Legion.const_get(ext_sym, false)
        return nil unless mod.is_a?(Module)

        # Check flat runners (e.g., Legion::Apollo::Runners::Request)
        if mod.const_defined?(:Runners, false)
          runners_mod = mod.const_get(:Runners, false)
          return runners_mod.const_get(runner_sym, false) if runners_mod.const_defined?(runner_sym, false)
        end

        nil
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.phase_wiring.core_library_runner',
                            extension: ext_sym, runner: runner_sym)
        nil
      end

      def deep_agentic_runner(ext_sym, runner_sym)
        return nil unless defined?(Legion::Extensions)
        return nil unless Legion::Extensions.const_defined?(:Agentic, false)

        agentic = Legion::Extensions::Agentic
        agentic.constants(false).each do |domain_const|
          domain_mod = agentic.const_get(domain_const, false)
          next unless domain_mod.is_a?(Module) && domain_mod.const_defined?(ext_sym, false)

          sub_mod = domain_mod.const_get(ext_sym, false)
          next unless sub_mod.is_a?(Module) && sub_mod.const_defined?(:Runners, false)

          runners_mod = sub_mod.const_get(:Runners, false)
          return runners_mod.const_get(runner_sym, false) if runners_mod.const_defined?(runner_sym, false)
        end
        nil
      end

      def locate_ext_mod(ext_sym)
        return nil unless defined?(Legion::Extensions)

        if Legion::Extensions.const_defined?(ext_sym, false)
          Legion::Extensions.const_get(ext_sym, false)
        elsif Legion::Extensions.const_defined?(:Agentic, false) &&
              Legion::Extensions::Agentic.const_defined?(ext_sym, false)
          Legion::Extensions::Agentic.const_get(ext_sym, false)
        end
      end

      def flat_runner(ext_mod, runner_sym)
        return nil unless ext_mod.const_defined?(:Runners, false)

        runners_mod = ext_mod.const_get(:Runners, false)
        runners_mod.const_get(runner_sym, false) if runners_mod.const_defined?(runner_sym, false)
      end

      def subdomain_runner(ext_mod, runner_sym)
        ext_mod.constants(false).each do |sub_const|
          sub_mod = ext_mod.const_get(sub_const, false)
          next unless sub_mod.is_a?(Module) && sub_mod.const_defined?(:Runners, false)

          runners_mod = sub_mod.const_get(:Runners, false)
          return runners_mod.const_get(runner_sym, false) if runners_mod.const_defined?(runner_sym, false)
        end
        nil
      end

      def mappings_for(value)
        value.is_a?(Array) ? value : [value]
      end

      def normalize_phase_result(value)
        return value unless value.is_a?(Array)

        members = value.map { |item| item.is_a?(Hash) ? item : { value: item } }
        return { status: :skipped, meaningful: false, reason: :empty_result } if members.empty?
        return members.first if members.size == 1

        status = combined_phase_status(members: members)
        # Retain the first (primary) provider's fields. Secondary failures and
        # overlapping fields remain visible rather than overwriting its result.
        payload = members.reverse_each.with_object({}) { |item, merged| merged.merge!(item) }
        payload.merge(handlers: members, status: status, success: status == :completed,
                      meaningful: members.any? { |item| meaningful_result?(item) })
      end

      def combined_phase_status(members:)
        statuses = members.map { |item| phase_status(item) }
        return :failed if statuses.include?(:failed)
        return :completed if statuses.all? { |status| status == :completed }
        return :partial if statuses.intersect?(%i[completed partial])
        return :unavailable if statuses.include?(:unavailable)
        return :deferred if statuses.include?(:deferred)

        :skipped
      end

      def normalize_prior_results(results)
        return {} unless results.is_a?(Hash)

        results.transform_values { |value| normalize_phase_result(value) }
      end

      def build_phase_handlers(runner_instances, identity: nil, phase_state: { signals: {} })
        PHASE_MAP.each_with_object({}) do |(phase, value), handlers|
          handler = build_phase_handler(phase, value, runner_instances, identity: identity, phase_state: phase_state)
          handlers[phase] = handler if handler
        end
      end

      def build_phase_handler(phase, value, runner_instances, identity: nil, phase_state: { signals: {} })
        return if value.nil?

        active = active_phase_mappings(value, runner_instances)
        return unless active.any? { |handler| handler[:instance] }

        lambda { |state:, signals:, prior_results:, **context|
          timed_phase_result(phase) do
            if context[:identity] && context[:identity] != identity
              next { status: :unavailable, reason: :identity_mismatch }
            end

            context = context.merge(identity: identity || context[:identity], runner_instances: runner_instances)
            conversation = context[:conversation_id]
            signals = phase_state[:signals][conversation] || [] if phase == :memory_audit && Array(signals).empty?
            result = execute_phase_handler(active, PHASE_ARGS[phase], phase: phase, state: state, signals: signals,
                                                                      prior_results: prior_results, context: context)
            if phase == :sensory_processing && meaningful_result?(result) && result[:filtered].is_a?(Array)
              phase_state[:signals][conversation] = result[:filtered]
              phase_state[:signals].shift if phase_state[:signals].size > 100
            end
            result
          end
        }
      end

      def active_phase_mappings(value, runner_instances)
        mappings_for(value).filter_map do |mapping|
          active_phase_mapping(mapping, runner_instances)
        end
      end

      def active_phase_mapping(mapping, runner_instances)
        instance_key = :"#{mapping[:ext]}_#{mapping[:runner]}"
        instance = runner_instances[instance_key]
        instance = nil unless instance.respond_to?(mapping[:fn])
        { instance: instance, fn: mapping[:fn], key: instance_key }
      end

      def execute_phase_handler(active, arg_builder, phase:, state:, signals:, prior_results:, context:)
        normalized_results = normalize_prior_results(prior_results)
        ctx = phase_handler_context(state: state, signals: signals, normalized_results: normalized_results,
                                    prior_results: prior_results, context: context)
        args = arg_builder ? arg_builder.call(ctx) : {}
        skipped_result = skipped_phase_result(args)
        return skipped_result if skipped_result

        results = active.map do |handler|
          timed_phase_result(phase) do
            result = invoke_phase_runner(phase: phase, handler: handler, args: args, context: ctx)
            result = result.merge(provider: handler[:key]) if result.is_a?(Hash)
            result
          end
        end
        normalize_phase_result(results)
      end

      def timed_phase_result(phase)
        started_at = ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
        result = yield
        annotate_phase_result(result, status: phase_status(result), started_at: started_at)
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.phase_wiring.phase_handler', phase: phase)
        annotate_phase_result({ error: e.class.name, message: e.message }, status: :failed, started_at: started_at)
      end

      def annotate_phase_result(result, status:, started_at:)
        elapsed_ms = ((::Process.clock_gettime(::Process::CLOCK_MONOTONIC) - started_at) * 1000.0).round(3)
        payload = result.is_a?(Hash) ? result.dup : { value: result }
        payload[:runner_status] = payload[:status] if payload[:status] && payload[:status] != status
        payload[:status] = status
        payload[:meaningful] = status == :completed unless payload.key?(:meaningful)
        payload[:elapsed_ms] = elapsed_ms
        payload
      end

      def phase_status(result)
        return :skipped unless result.is_a?(Hash) && !result.empty?
        return :failed if result[:error] || %i[error failed failure timeout].include?(result[:status])
        return :deferred if result[:deferred]
        return :skipped if result[:skip] || result[:skipped] || result[:status] == :no_result
        return result[:status] if %i[unavailable deferred skipped partial no_handler
                                     budget_skipped].include?(result[:status])
        return :skipped if %i[no_winner below_threshold missing_trace_ids no_candidates].include?(result[:reason])
        return :failed if result[:success] == false
        return :skipped if empty_phase_result?(result: result)
        return :skipped if (result.keys - %i[success status elapsed_ms provider
                                             reason]).empty? && result[:status] != :completed

        :completed
      end

      def empty_phase_result?(result:)
        return true if result[:meaningful] == false || result[:found] == false || result[:resolved] == false
        return true if result[:linked] == false && !result[:coactivated]

        %i[traces filtered agenda conflicts].any? do |key|
          result[key].is_a?(Array) && result[key].empty?
        end
      end

      def meaningful_result?(result)
        result.is_a?(Hash) && phase_status(result) == :completed && result[:meaningful] != false
      end

      def supports_keyword?(runner:, method_name:, keyword:)
        return false unless runner.respond_to?(method_name)
        if runner.respond_to?(:supports_keyword?)
          return runner.supports_keyword?(method_name: method_name,
                                          keyword: keyword)
        end

        runner.method(method_name).parameters.any? { |kind, name| %i[key keyreq].include?(kind) && name == keyword }
      end

      def invoke_phase_runner(phase:, handler:, args:, context:)
        runner = handler[:instance]
        return { status: :unavailable, reason: :missing_handler } unless runner

        unavailable = runner_unavailability(runner: runner, method_name: handler[:fn], args: args, context: context)
        return unavailable if unavailable

        case phase
        when :memory_retrieval, :memory_audit
          retrieve_relevant_memory(runner: runner, context: context, audit: phase == :memory_audit)
        when :global_workspace
          compete_for_workspace(runner: runner, context: context)
        when :association_walk
          associate_memory(runner: runner, args: args, context: context)
        else
          if phase == :prediction_engine
            args = calibrated_prediction_args(runner: runner, args: args, identity: context[:identity])
          end
          result = normalize_phase_result(runner.public_send(handler[:fn], **args, identity: context[:identity]))
          annotate_provider_result(phase: phase, result: result, args: args, context: context)
        end
      end

      def runner_unavailability(runner:, method_name:, args:, context:)
        if %i[reflect_on_bonds sync_partner_knowledge].include?(method_name) && context[:identity].nil?
          return { status: :unavailable, reason: :authenticated_identity_required }
        end
        if context[:identity] && %i[reflect_on_bonds sync_partner_knowledge predict].include?(method_name) &&
           !supports_keyword?(runner: runner, method_name: method_name, keyword: :identity)
          return { status: :unavailable, reason: :identity_scope_unsupported }
        end
        # Preference extraction is a background LLM operation, never recursive
        # work on the cognitive heartbeat.
        return { status: :deferred, reason: :background_partner_knowledge } if method_name == :sync_partner_knowledge
        if method_name == :predict && args[:description] &&
           !%i[description context].all? do |keyword|
             supports_keyword?(runner: runner, method_name: :predict, keyword: keyword)
           end
          return { status: :unavailable, reason: :stated_prediction_unsupported }
        end

        nil
      end

      def calibrated_prediction_args(runner:, args:, identity:)
        return args unless supports_keyword?(runner: runner, method_name: :prediction_accuracy, keyword: :identity)

        accuracy = runner.prediction_accuracy(identity: identity)
        return args unless accuracy[:total_outcomes].to_i.positive? && accuracy[:accuracy].is_a?(Numeric)

        args.merge(confidence: accuracy[:accuracy].clamp(0.0, 1.0))
      end

      def annotate_provider_result(phase:, result:, args:, context:)
        return result unless result.is_a?(Hash)

        case phase
        when :prediction_engine
          claim = args.dig(:context, :prediction_claim)
          result.merge(prediction_kind: claim ? :stated_claim : :heuristic,
                       outcome_verifiable: !claim.nil?, prediction_claim: claim)
        when :action_selection
          meaningful = !Array(result[:new_intentions]).empty? || result[:current_intention].is_a?(Hash) ||
                       result[:proactive_outreach].is_a?(Hash)
          result.merge(meaningful: meaningful, task_completed: false, outcome: :intention_proposed)
        when :metacognition
          prior = context[:prior_results]
          result.merge(demonstrated_capabilities: demonstrated_capabilities(prior),
                       cognitive: { health: prior.dig(:post_tick_reflection, :cognitive_health),
                                    attention: prior[:sensory_processing], prediction: prior[:prediction_engine] })
        else
          result
        end
      end

      def prediction_args(context)
        signal = decision_signal(context)
        return { skip: true, reason: :no_attended_signal } unless signal

        request = context[:prediction_request]
        claim = prediction_claim(request: request)
        return { skip: true, status: :unavailable, reason: :invalid_prediction_request } if !request.nil? && !claim
        if claim && (context[:identity].to_s.strip.empty? || context[:exchange_id].to_s.strip.empty?)
          return { skip: true, status: :unavailable, reason: :prediction_correlation_required }
        end

        args = { mode: :functional_mapping, identity: context[:identity],
                 context: { signal: signal, memory: context.dig(:prior_results, :memory_retrieval),
                            conversation_id: context[:conversation_id], exchange_id: context[:exchange_id] } }
        if claim
          args[:description] = claim[:description]
          args[:context][:prediction_claim] = claim
          args[:context][:domain] = claim[:domain]
        end
        args
      end

      def prediction_claim(request:)
        return unless request.is_a?(Hash)
        return unless request[:domain].is_a?(String) || request[:domain].is_a?(Symbol)
        return if request[:domain].to_s.strip.empty?
        return unless request[:description].is_a?(String) && !request[:description].strip.empty?
        return unless comparable_outcome?(value: request[:expected_outcome])

        expected = request[:expected_outcome]
        { domain: request[:domain].to_s.strip, description: request[:description].strip,
          expected_outcome: expected.is_a?(String) ? expected.strip : expected }
      end

      def comparable_outcome?(value:)
        case value
        when String then !value.strip.empty?
        when Float then value.finite?
        when Integer, TrueClass, FalseClass then true
        else false
        end
      end

      def working_memory_inputs(context)
        results = (context[:prior_results] || {}).dup
        memory = results[:memory_retrieval]
        return results unless memory.is_a?(Hash)

        if meaningful_result?(memory) || memory[:reason] == :no_candidates
          results[:memory_retrieval] = memory.merge(traces: memory_traces(memory))
        else
          results.delete(:memory_retrieval)
        end
        results
      end

      def decision_signals(context)
        attention = context.dig(:prior_results, :sensory_processing)
        return Array(context[:signals]).grep(Hash) unless attention.is_a?(Hash)
        return [] unless meaningful_result?(attention)
        return attention[:filtered] if attention[:filtered].is_a?(Array)

        []
      end

      def decision_signal(context)
        signals = decision_signals(context)
        signals.find { |signal| signal[:source_type] == :human_direct } || signals.first
      end

      def memory_traces(result)
        return [] unless result.is_a?(Hash) && meaningful_result?(result)

        Array(result[:traces]).filter_map do |entry|
          next unless entry.is_a?(Hash)

          entry[:trace].is_a?(Hash) ? entry[:trace] : entry
        end
      end

      def trace_authorized?(trace:, identity:)
        Array(trace[:domain_tags]).all? do |tag|
          tag = tag.to_s
          !tag.start_with?('partner:', 'owner:') ||
            (!identity.to_s.strip.empty? && ["partner:#{identity}", "owner:#{identity}"].include?(tag))
        end
      end

      def memory_domains(signals:)
        signals.flat_map { |signal| [signal[:domain], *Array(signal[:tags])] }
               .compact.map(&:to_s).reject do |tag|
          tag.empty? || tag.start_with?('partner:', 'owner:') || MEMORY_METADATA_TAGS.include?(tag)
        end.uniq.first(5)
      end

      def relevant_trace?(trace:, domains:, signals:)
        return true if Array(trace[:domain_tags]).map(&:to_s).intersect?(domains)

        terms = signals.flat_map do |signal|
          (signal[:value] || signal[:content]).to_s.downcase.scan(/[[:alnum:]]{4,}/)
        end.uniq
        content = trace[:content_payload].to_s.downcase
        terms.any? { |term| content.match?(/\b#{Regexp.escape(term)}\b/) }
      end

      def retrieve_relevant_memory(runner:, context:, audit:)
        unless supports_keyword?(runner: runner, method_name: :retrieve_by_domain, keyword: :domain_tag) &&
               supports_keyword?(runner: runner, method_name: :retrieve_ranked, keyword: :trace_ids)
          return { status: :unavailable, reason: :authorized_candidate_api_unavailable }
        end

        signals = decision_signals(context)
        domains = memory_domains(signals: signals)
        domains |= memory_domains(signals: [{ tags: context[:memory_domain_tags] }])
        identity = context[:identity]
        selectors = domains.first(5)
        selectors += ["partner:#{identity}", "owner:#{identity}"] if identity && !identity.to_s.strip.empty?
        if selectors.empty? || (domains.empty? && signals.empty?)
          return { status: :skipped, reason: :no_relevant_query,
                   traces: [] }
        end

        setting = audit ? :memory_audit_limit : :memory_retrieval_limit
        limit = knowledge_setting(setting, audit ? 20 : 10).to_i.clamp(1, 100)
        candidates = relevant_memory_candidates(runner: runner, selectors: selectors, limit: limit,
                                                identity: identity, domains: domains, signals: signals)
        return candidates if candidates.is_a?(Hash)
        return { status: :skipped, reason: :no_candidates, traces: [], domain: domains.first } if candidates.empty?

        rank_authorized_memory(runner: runner, candidates: candidates, identity: identity, domain: domains.first)
      end

      def relevant_memory_candidates(runner:, selectors:, limit:, identity:, domains:, signals:)
        candidates = selectors.flat_map do |domain|
          result = runner.retrieve_by_domain(domain_tag: domain, limit: limit)
          return result if %i[failed unavailable deferred].include?(phase_status(result))

          Array(result[:traces])
        end
        candidates.select! do |trace|
          trace.is_a?(Hash) && trace[:trace_id] && trace_authorized?(trace: trace, identity: identity) &&
            relevant_trace?(trace: trace, domains: domains, signals: signals)
        end
        candidates.uniq! { |trace| trace[:trace_id] }
        candidates.first(limit)
      end

      def rank_authorized_memory(runner:, candidates:, identity:, domain:)
        ids = candidates.map { |trace| trace[:trace_id] }
        result = runner.retrieve_ranked(trace_ids: ids, identity: identity)
        return result unless meaningful_result?(result)

        ranked = Array(result[:traces]).select do |entry|
          trace = entry.is_a?(Hash) && entry[:trace]
          trace.is_a?(Hash) && ids.include?(trace[:trace_id]) && trace_authorized?(trace: trace, identity: identity)
        end
        result.merge(traces: ranked, count: ranked.size, candidate_count: ids.size,
                     domain: domain, meaningful: !ranked.empty?)
      end

      def association_args(context)
        traces = memory_traces(context.dig(:prior_results, :memory_audit))
                 .select { |trace| trace_authorized?(trace: trace, identity: context[:identity]) }
        pair = traces.combination(2).find do |left, right|
          left_tags = Array(left[:domain_tags]).map(&:to_s)
          right_tags = Array(right[:domain_tags]).map(&:to_s)
          left_owners = left_tags.select { |tag| tag.start_with?('partner:', 'owner:') }
          right_owners = right_tags.select { |tag| tag.start_with?('partner:', 'owner:') }
          shared = (left_tags & right_tags) - left_owners - MEMORY_METADATA_TAGS
          left[:trace_id] != right[:trace_id] && left_owners.sort == right_owners.sort && !shared.empty?
        end
        return { skip: true, reason: :no_related_candidates } unless pair

        { trace_id_a: pair[0][:trace_id], trace_id_b: pair[1][:trace_id] }
      end

      def associate_memory(runner:, args:, context:)
        traces = context.dig(:runner_instances, :Memory_Traces)
        unless traces.respond_to?(:get_trace)
          return { status: :unavailable,
                   reason: :association_verification_unavailable }
        end

        pair = [args[:trace_id_a], args[:trace_id_b]].map { |id| traces.get_trace(trace_id: id)[:trace] }
        unless pair.all? { |trace| trace.is_a?(Hash) && trace_authorized?(trace: trace, identity: context[:identity]) }
          return { status: :unavailable, reason: :association_candidate_unavailable }
        end

        result = runner.hebbian_link(**args)
        return result if phase_status(result) == :failed

        left = traces.get_trace(trace_id: args[:trace_id_a])[:trace]
        right = traces.get_trace(trace_id: args[:trace_id_b])[:trace]
        linked = left.is_a?(Hash) && right.is_a?(Hash) &&
                 Array(left[:associated_traces]).include?(args[:trace_id_b]) &&
                 Array(right[:associated_traces]).include?(args[:trace_id_a])
        result.merge(args, linked: linked, coactivated: true, meaningful: true)
      end

      def compete_for_workspace(runner:, context:)
        unless runner.respond_to?(:submit_for_broadcast)
          return { status: :unavailable,
                   reason: :submission_api_unavailable }
        end
        if context[:identity] && (context[:conversation_id].to_s.empty? || context[:exchange_id].to_s.empty?)
          return { status: :deferred, reason: :missing_correlation }
        end

        scope = context.slice(:identity, :conversation_id, :exchange_id)
        candidates = workspace_candidates(context: context, scope: scope)
        return { status: :skipped, reason: :no_candidates } if candidates.empty?

        submissions = candidates.map { |candidate| runner.submit_for_broadcast(**candidate) }
        return { status: :skipped, reason: :no_admitted_candidates } unless submissions.any? do |result|
          result[:success] == true
        end

        result = runner.run_competition
        return result unless result[:success] == true
        return { status: :deferred, reason: :stale_workspace_selection } unless result.dig(:broadcast, :content,
                                                                                           :scope) == scope

        result.merge(meaningful: true, submitted: submissions.count { |submission| submission[:success] == true })
      end

      def workspace_candidates(context:, scope:)
        candidates = decision_signals(context).first(10).filter_map do |signal|
          next if (signal[:value] || signal[:content]).to_s.strip.empty?

          { content: { signal: signal, scope: scope }, source: :attention, domain: signal[:domain] || :general,
            salience: (signal[:attention_score] || signal[:salience] || 0.0).to_f.clamp(0.0, 1.0) }
        end
        candidates.concat(memory_traces(context.dig(:prior_results, :memory_retrieval)).first(10).filter_map do |trace|
          next if trace[:content_payload].to_s.strip.empty?

          { content: { trace: trace, scope: scope }, source: :memory,
            domain: Array(trace[:domain_tags]).find { |tag| !tag.to_s.start_with?('partner:', 'owner:') } || :general,
            salience: trace[:strength].to_f.clamp(0.0, 1.0) }
        end)
      end

      def demonstrated_capabilities(results)
        normalize_prior_results(results).transform_values do |result|
          { status: phase_status(result), ready: meaningful_result?(result) }
        end
      end

      def phase_handler_context(state:, signals:, normalized_results:, prior_results:, context:)
        {
          state: state,
          signals: signals,
          prior_results: normalized_results,
          raw_prior_results: prior_results,
          current_signal: signals&.last,
          valences: collect_valences(normalized_results)
        }.merge(context)
      end

      def skipped_phase_result(args)
        return unless args.is_a?(Hash) && args[:skip]

        reason = args[:reason] || args[:skipped] || :phase_wiring_skip
        { status: args[:status] || :skipped, meaningful: false, reason: reason }
      end

      def discover_available_extensions
        available = {}

        PHASE_MAP.each_value do |value|
          next if value.nil?

          mappings_for(value).each do |mapping|
            key = :"#{mapping[:ext]}_#{mapping[:runner]}"
            next if available.key?(key)

            runner_class = resolve_runner_class(mapping[:ext], mapping[:runner])
            available[key] = { ext: mapping[:ext], runner: mapping[:runner], loaded: !runner_class.nil? }
          end
        end

        available
      end

      def build_promotion_content(prior_results)
        parts = [
          extract_association(prior_results[:association_walk]),
          extract_conflicts(prior_results[:contradiction_resolution]),
          extract_reflection(prior_results[:dream_reflection]),
          extract_agenda(prior_results[:agenda_formation])
        ].compact

        return nil if parts.empty?

        "Dream cycle synthesis: #{parts.join('. ')}"
      end

      def bond_state_from(ctx)
        return {} unless ctx[:identity]

        prior = ctx.dig(:prior_results, :partner_reflection)
        bond_state = prior.is_a?(Array) ? (prior.find { |item| item.is_a?(Hash) } || {}) : (prior || {})
        return bond_state if meaningful_result?(bond_state)

        live_partner_reflection(ctx)
      end

      def live_partner_reflection(ctx)
        return {} unless ctx[:identity]

        return {} unless defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:registry)

        runners = ctx[:runner_instances]
        runners ||= Legion::Gaia.registry&.runner_instances_for(identity: ctx[:identity])
        runner = runners&.dig(:Social_Attachment)
        return {} unless runner.respond_to?(:reflect_on_bonds)
        if ctx[:identity] && !supports_keyword?(runner: runner, method_name: :reflect_on_bonds, keyword: :identity)
          return {}
        end

        result = runner.reflect_on_bonds(tick_results: ctx[:prior_results] || {}, bond_summary: {},
                                         identity: ctx[:identity])
        result.is_a?(Hash) ? result : {}
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.phase_wiring.live_partner_reflection')
        {}
      end

      def extract_association(assoc)
        return unless assoc.is_a?(Hash) && assoc[:linked]

        "Association: linked trace #{assoc[:trace_id_a]} to #{assoc[:trace_id_b]}"
      end

      def extract_conflicts(conflicts)
        return unless conflicts.is_a?(Hash) && conflicts[:resolved].to_i.positive?

        "Resolved #{conflicts[:resolved]} contradiction(s)"
      end

      def extract_reflection(reflection)
        return unless reflection.is_a?(Hash) && meaningful_result?(reflection)

        content = reflection[:insight] || reflection[:reflection]
        return unless content.is_a?(String) && !content.empty?

        "Insight: #{content[0, 500]}"
      end

      def extract_agenda(agenda)
        return unless agenda.is_a?(Hash) && agenda[:agenda].is_a?(Array) && agenda[:agenda].any?

        items = agenda[:agenda].first(3).map { |a| a.is_a?(Hash) ? (a[:question] || a[:topic]) : a.to_s }
        "Agenda: #{items.compact.join('; ')}" if items.compact.any?
      end

      def collect_valences(prior_results)
        return [] unless prior_results.is_a?(Hash)

        valence_result = prior_results[:emotional_evaluation]
        return [] unless valence_result.is_a?(Hash) && valence_result[:valence]

        [valence_result[:valence]]
      end

      def partner_observations_from(ctx)
        observations = ctx[:partner_observations]
        unless observations.is_a?(Array)
          state = ctx[:state]
          observations = state[:partner_observations] if state.is_a?(Hash)
          observations = state.partner_observations if state.respond_to?(:partner_observations)
        end
        observations = Array(observations)
        return [] unless ctx[:identity]

        observations.select { |observation| observation.is_a?(Hash) && observation[:identity] == ctx[:identity] }
      end
    end
  end
end
