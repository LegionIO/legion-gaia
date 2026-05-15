# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module PhaseWiring # rubocop:disable Metrics/ModuleLength
      extend Legion::Logging::Helper

      PHASE_MAP = {
        sensory_processing: { ext: :Attention, runner: :Attention, fn: :filter_signals },
        emotional_evaluation: { ext: :Emotion, runner: :Valence,       fn: :evaluate_valence },
        memory_retrieval: { ext: :Memory, runner: :Traces, fn: :retrieve_and_reinforce },
        knowledge_retrieval: { ext: :Apollo, runner: :Request, fn: :retrieve },
        identity_entropy_check: { ext: :Identity, runner: :Identity, fn: :check_entropy },
        working_memory_integration: [
          { ext: :Curiosity, runner: :Curiosity,   fn: :detect_gaps },
          { ext: :Synapse,   runner: :GaiaReport,  fn: :gaia_summary }
        ],
        procedural_check: { ext: :Coldstart, runner: :Coldstart, fn: :coldstart_progress },
        prediction_engine: { ext: :Prediction, runner: :Prediction, fn: :predict },
        mesh_interface: { ext: :Mesh, runner: :Mesh, fn: :mesh_status },
        social_cognition: { ext: :Social, runner: :Social, fn: :update_social },
        theory_of_mind: { ext: :Social, runner: :TheoryOfMind, fn: :update_theory_of_mind },
        gut_instinct: { ext: :Emotion, runner: :Gut, fn: :gut_instinct },
        action_selection: { ext: :Volition, runner: :Volition, fn: :form_intentions },
        memory_consolidation: { ext: :Memory, runner: :Consolidation, fn: :decay_cycle },
        homeostasis_regulation: { ext: :Homeostasis, runner: :Homeostasis, fn: :regulate },
        post_tick_reflection: [
          { ext: :Reflection, runner: :Reflection,  fn: :reflect },
          { ext: :Synapse,    runner: :GaiaReport,  fn: :gaia_reflection },
          { ext: :Detect,     runner: :TaskObserver, fn: :observe }
        ],

        # Dream cycle phases
        memory_audit: { ext: :Memory, runner: :Traces, fn: :retrieve_ranked },
        association_walk: { ext: :Memory, runner: :Consolidation, fn: :hebbian_link },
        contradiction_resolution: { ext: :Conflict, runner: :Conflict, fn: :active_conflicts },
        agenda_formation: { ext: :Curiosity, runner: :Curiosity, fn: :form_agenda },
        curiosity_execution: { ext: :Curiosity, runner: :Curiosity, fn: :self_inquire },
        consolidation_commit: { ext: :Memory, runner: :Consolidation, fn: :migrate_tier },
        knowledge_promotion: { ext: :Apollo, runner: :Knowledge, fn: :handle_ingest },
        dream_reflection: { ext: :Reflection, runner: :Reflection, fn: :reflect },
        partner_reflection: [
          { ext: :Social, runner: :Attachment, fn: :reflect_on_bonds },
          { ext: :Social, runner: :Calibration, fn: :sync_partner_knowledge }
        ],
        dream_narration: { ext: :Narrator, runner: :Narrator, fn: :narrate },

        # lex-agentic-imagination
        dream_cycle: { ext: :Dream,        runner: :DreamCycle, fn: :execute_dream_cycle },
        creativity_tick: { ext: :Creativity, runner: :Creativity, fn: :creative_tick },
        lucid_dream: { ext: :Lucidity, runner: :CognitiveLucidity, fn: :begin_dream },

        # lex-agentic-defense
        epistemic_vigilance: { ext: :EpistemicVigilance, runner: :EpistemicVigilance, fn: :assess_epistemic_claim },

        # lex-agentic-inference
        predictive_processing: { ext: :PredictiveProcessing, runner: :PredictiveProcessing, fn: :predict_from_model },
        free_energy: { ext: :FreeEnergy, runner: :FreeEnergy, fn: :minimize_free_energy },

        # lex-agentic-self
        metacognition: { ext: :Metacognition, runner: :Metacognition, fn: :introspect },
        default_mode_network: { ext: :DefaultModeNetwork, runner: :DefaultModeNetwork,
                                fn: :generate_idle_thought },

        # lex-agentic-executive
        prospective_memory: { ext: :ProspectiveMemory, runner: :ProspectiveMemory, fn: :monitor_intention },

        # lex-agentic-language
        inner_speech: { ext: :InnerSpeech, runner: :InnerSpeech, fn: :inner_speak },

        # lex-agentic-integration
        global_workspace: { ext: :GlobalWorkspace, runner: :GlobalWorkspace, fn: :run_competition }
      }.freeze

      PHASE_ARGS = {
        sensory_processing: lambda { |ctx|
          { signals: ctx[:signals] || [],
            active_wonders: ctx.dig(:prior_results, :agenda_formation, :agenda) || [] }
        },
        emotional_evaluation: lambda { |ctx|
          { signal: ctx[:current_signal] || {}, source_type: :ambient,
            human_observations: partner_observations_from(ctx) }
        },
        memory_retrieval: lambda { |ctx|
          return { skip: true, reason: :idle_no_signals } if Array(ctx[:signals]).empty?

          { limit: knowledge_setting(:memory_retrieval_limit, 10) }
        },
        knowledge_retrieval: lambda { |ctx|
          human_signal = ctx[:signals]&.select { |s| s.is_a?(Hash) && s[:source_type] == :human_direct }&.last
          current_signal = human_signal || ctx[:signals]&.last
          memory_results = ctx.dig(:prior_results, :memory_retrieval)
          skip_threshold = knowledge_setting(:memory_skip_threshold, 0.8)

          if current_signal.nil? || (memory_results.is_a?(Hash) &&
             memory_results[:traces]&.any? { |t| t[:strength].to_f > skip_threshold })
            return { skip: true }
          end

          {
            text:                    current_signal[:value] || current_signal[:content] || current_signal.to_s,
            limit:                   knowledge_setting(:retrieval_limit, 5),
            min_confidence:          knowledge_setting(:retrieval_min_confidence, 0.3),
            tags:                    current_signal[:tags],
            requesting_principal_id: current_signal[:principal_id]
          }
        },
        identity_entropy_check: ->(_ctx) { {} },
        procedural_check: ->(_ctx) { {} },
        prediction_engine: lambda { |ctx|
          return { skip: true, reason: :idle_no_signals } if Array(ctx[:signals]).empty?

          { mode: :functional_mapping, context: ctx[:prior_results] || {} }
        },
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
            cognitive_state: build_cognitive_state(ctx[:prior_results] || {}),
            bond_state: bond_state_from(ctx) }
        },
        working_memory_integration: ->(ctx) { { prior_results: ctx[:prior_results] || {} } },
        memory_consolidation: ->(_ctx) { { maintenance: false } },
        homeostasis_regulation: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        post_tick_reflection: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {}, since: observer_cursor_from(ctx) }
        },
        memory_audit: ->(_ctx) { { limit: knowledge_setting(:memory_audit_limit, 20) } },
        association_walk: lambda { |ctx|
          audit = ctx.dig(:prior_results, :memory_audit)
          traces = audit.is_a?(Hash) ? audit[:traces] : nil
          traces = [] unless traces.is_a?(Array) && traces.size >= 2
          { trace_id_a: traces.dig(0, :trace_id), trace_id_b: traces.dig(1, :trace_id) }
        },
        contradiction_resolution: ->(_ctx) { {} },
        agenda_formation: ->(_ctx) { {} },
        curiosity_execution: ->(_ctx) { { max_wonders: 1 } },
        consolidation_commit: ->(_ctx) { {} },
        knowledge_promotion: lambda { |ctx|
          content = build_promotion_content(ctx[:prior_results] || {})
          return { skip: true } if content.nil?

          { content: content, content_type: :observation, tags: %w[dream_cycle promoted],
            source_agent: 'gaia', source_channel: 'dream_cycle' }
        },
        dream_reflection: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        partner_reflection: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {},
            bond_summary: ctx.dig(:prior_results, :dream_reflection) || {} }
        },
        dream_narration: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {}, cognitive_state: { source: :dream } }
        },

        # lex-agentic-imagination
        dream_cycle: ->(_ctx) { {} },
        creativity_tick: ->(ctx)  { { tick_results: ctx[:prior_results] || {} } },
        lucid_dream: ->(_ctx) { { theme: :reflection, content: 'autonomous dream cycle' } },

        # lex-agentic-defense
        epistemic_vigilance: ->(_ctx) { { claim_id: nil } },

        # lex-agentic-inference
        predictive_processing: lambda { |ctx|
          { domain: ctx.dig(:prior_results, :memory_retrieval, :domain) || :general, context: {} }
        },
        free_energy: ->(_ctx) { { belief_id: nil, mode: :perceptual } },

        # lex-agentic-self
        metacognition: ->(ctx) { { tick_results: ctx[:prior_results] || {}, subsystem_states: {} } },
        default_mode_network: ->(_ctx) { {} },

        # lex-agentic-executive
        prospective_memory: ->(_ctx) { { intention_id: nil } },

        # lex-agentic-language
        inner_speech: lambda { |ctx|
          { content: ctx.dig(:prior_results, :action_selection, :goal).to_s, mode: :narrating, topic: :general }
        },

        # lex-agentic-integration
        global_workspace: ->(_ctx) { {} }
      }.freeze

      @previous_reflection = {}
      @previous_reflection_mutex = Mutex.new

      module_function

      def previous_reflection
        @previous_reflection_mutex.synchronize { @previous_reflection || {} }
      end

      def capture_tick_results(results)
        return unless results.is_a?(Hash)

        refl = results[:post_tick_reflection]
        @previous_reflection_mutex.synchronize do
          @previous_reflection = refl if refl.is_a?(Hash) && refl[:status] != :skipped
        end
      end

      def build_cognitive_state(prior_results)
        {
          curiosity: extract_curiosity_state(prior_results),
          reflection: extract_reflection_state,
          prediction: extract_prediction_state(prior_results),
          mesh: extract_mesh_state(prior_results),
          trust: extract_trust_state(prior_results),
          emotion: extract_emotion_state(prior_results),
          gut: prior_results[:gut_instinct]
        }
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

      def extract_reflection_state
        refl = previous_reflection
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

        compact = value.compact
        return {} if compact.empty?
        return compact.first if compact.size == 1
        return compact.each_with_object({}) { |item, merged| merged.merge!(item) } if compact.all?(Hash)

        compact
      end

      def normalize_prior_results(results)
        return {} unless results.is_a?(Hash)

        results.transform_values { |value| normalize_phase_result(value) }
      end

      def build_phase_handlers(runner_instances)
        PHASE_MAP.each_with_object({}) do |(phase, value), handlers|
          handler = build_phase_handler(phase, value, runner_instances)
          handlers[phase] = handler if handler
        end
      end

      def build_phase_handler(phase, value, runner_instances)
        return if value.nil?

        active = active_phase_mappings(value, runner_instances)
        return if active.empty?

        arg_builder = PHASE_ARGS[phase]
        lambda { |state:, signals:, prior_results:, **context|
          timed_phase_result(phase) do
            execute_phase_handler(
              active,
              arg_builder,
              state: state,
              signals: signals,
              prior_results: prior_results,
              context: context
            )
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
        return unless instance

        { instance: instance, fn: mapping[:fn] }
      end

      def execute_phase_handler(active, arg_builder, state:, signals:, prior_results:, context:)
        normalized_results = normalize_prior_results(prior_results)
        ctx = phase_handler_context(
          state: state,
          signals: signals,
          normalized_results: normalized_results,
          prior_results: prior_results,
          context: context
        )
        args = arg_builder ? arg_builder.call(ctx) : {}

        skipped_result = skipped_phase_result(args)
        return skipped_result if skipped_result

        results = active.map { |handler| handler[:instance].send(handler[:fn], **args) }
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
        payload[:status] ||= status
        payload[:elapsed_ms] ||= elapsed_ms
        payload
      end

      def phase_status(result)
        return result[:status] if result.is_a?(Hash) && result[:status]
        return :skipped if result.is_a?(Hash) && result[:skip]
        return :skipped if result.is_a?(Hash) && result[:skipped]

        :completed
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
        { status: :skipped, reason: reason }
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
        prior = ctx.dig(:prior_results, :partner_reflection)
        bond_state = prior.is_a?(Array) ? (prior.find { |item| item.is_a?(Hash) } || {}) : (prior || {})
        return bond_state if bond_state.is_a?(Hash) && !bond_state.empty?

        live_partner_reflection(ctx)
      end

      def live_partner_reflection(ctx)
        return {} unless defined?(Legion::Gaia) && Legion::Gaia.respond_to?(:registry)

        runner = Legion::Gaia.registry&.runner_instances&.dig(:Social_Attachment)
        return {} unless runner.respond_to?(:reflect_on_bonds)

        result = runner.reflect_on_bonds(tick_results: ctx[:prior_results] || {}, bond_summary: {})
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
        return unless reflection.is_a?(Hash) && reflection[:insight].is_a?(String) && !reflection[:insight].empty?

        "Insight: #{reflection[:insight][0, 500]}"
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
        return observations if observations.is_a?(Array)

        state = ctx[:state]
        return state[:partner_observations] || [] if state.is_a?(Hash)
        return state.partner_observations if state.respond_to?(:partner_observations)

        []
      end

      def observer_cursor_from(ctx)
        return ctx[:last_observer_tick] if ctx.key?(:last_observer_tick)

        state = ctx[:state]
        return state[:last_observer_tick] if state.is_a?(Hash)
        return state.last_observer_tick if state.respond_to?(:last_observer_tick)

        nil
      end
    end
  end
end
