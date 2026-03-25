# frozen_string_literal: true

module Legion
  module Gaia
    module PhaseWiring # rubocop:disable Metrics/ModuleLength
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
        consolidation_commit: { ext: :Memory, runner: :Consolidation, fn: :migrate_tier },
        knowledge_promotion: { ext: :Apollo, runner: :Knowledge, fn: :handle_ingest },
        dream_reflection: { ext: :Reflection, runner: :Reflection, fn: :reflect },
        dream_narration: { ext: :Narrator, runner: :Narrator, fn: :narrate }
      }.freeze

      PHASE_ARGS = {
        sensory_processing: lambda { |ctx|
          { signals: ctx[:signals] || [],
            active_wonders: ctx.dig(:prior_results, :agenda_formation, :agenda) || [] }
        },
        emotional_evaluation: ->(ctx) { { signal: ctx[:current_signal] || {}, source_type: :ambient } },
        memory_retrieval: ->(_ctx) { { limit: knowledge_setting(:memory_retrieval_limit, 10) } },
        knowledge_retrieval: lambda { |ctx|
          current_signal = ctx[:signals]&.last
          memory_results = ctx.dig(:prior_results, :memory_retrieval)
          skip_threshold = knowledge_setting(:memory_skip_threshold, 0.8)

          if current_signal.nil? || (memory_results.is_a?(Hash) &&
             memory_results[:traces]&.any? { |t| t[:strength].to_f > skip_threshold })
            return { skip: true }
          end

          {
            text: current_signal[:content] || current_signal.to_s,
            limit: knowledge_setting(:retrieval_limit, 5),
            min_confidence: knowledge_setting(:retrieval_min_confidence, 0.3),
            tags: current_signal[:tags]
          }
        },
        identity_entropy_check: ->(_ctx) { {} },
        procedural_check: ->(_ctx) { {} },
        prediction_engine: ->(ctx) { { mode: :functional_mapping, context: ctx[:prior_results] || {} } },
        mesh_interface: ->(_ctx) { {} },
        social_cognition: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        theory_of_mind: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        gut_instinct: ->(ctx) { { valences: ctx[:valences] || [] } },
        action_selection: ->(ctx) { { tick_results: ctx[:prior_results] || {}, cognitive_state: {} } },
        working_memory_integration: ->(ctx) { { prior_results: ctx[:prior_results] || {} } },
        memory_consolidation: ->(_ctx) { {} },
        homeostasis_regulation: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        post_tick_reflection: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {}, since: ctx.dig(:state, :last_observer_tick) }
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
        consolidation_commit: ->(_ctx) { {} },
        knowledge_promotion: lambda { |ctx|
          content = build_promotion_content(ctx[:prior_results] || {})
          return { skip: true } if content.nil?

          { content: content, content_type: :observation, tags: %w[dream_cycle promoted],
            source_agent: 'gaia', source_channel: 'dream_cycle' }
        },
        dream_reflection: ->(ctx) { { tick_results: ctx[:prior_results] || {} } },
        dream_narration: lambda { |ctx|
          { tick_results: ctx[:prior_results] || {}, cognitive_state: { source: :dream } }
        }
      }.freeze

      module_function

      def knowledge_setting(key, default)
        return default unless defined?(Legion::Settings) && !Legion::Settings[:gaia].nil?

        Legion::Settings[:gaia].dig(:knowledge, key) || default
      rescue StandardError
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
      rescue StandardError
        nil
      end

      def deep_agentic_runner(ext_sym, runner_sym)
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

      def build_phase_handlers(runner_instances)
        handlers = {}

        PHASE_MAP.each do |phase, value|
          next if value.nil?

          maps = mappings_for(value)
          active = maps.filter_map do |mapping|
            instance_key = :"#{mapping[:ext]}_#{mapping[:runner]}"
            instance = runner_instances[instance_key]
            next unless instance

            { instance: instance, fn: mapping[:fn] }
          end
          next if active.empty?

          arg_builder = PHASE_ARGS[phase]

          handlers[phase] = lambda { |state:, signals:, prior_results:|
            ctx = { state: state, signals: signals, prior_results: prior_results,
                    current_signal: signals&.last, valences: collect_valences(prior_results) }
            args = arg_builder ? arg_builder.call(ctx) : {}
            results = active.map { |h| h[:instance].send(h[:fn], **args) }
            results.size == 1 ? results.first : results
          }
        end

        handlers
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
          extract_consolidation(prior_results[:consolidation_commit]),
          extract_reflection(prior_results[:dream_reflection]),
          extract_agenda(prior_results[:agenda_formation])
        ].compact

        return nil if parts.empty?

        "Dream cycle synthesis: #{parts.join('. ')}"
      end

      def extract_association(assoc)
        return unless assoc.is_a?(Hash) && assoc[:linked]

        "Association: linked trace #{assoc[:trace_id_a]} to #{assoc[:trace_id_b]}"
      end

      def extract_conflicts(conflicts)
        return unless conflicts.is_a?(Hash) && conflicts[:resolved].to_i.positive?

        "Resolved #{conflicts[:resolved]} contradiction(s)"
      end

      def extract_consolidation(consol)
        return unless consol.is_a?(Hash) && consol[:migrated].to_i.positive?

        "Consolidated #{consol[:migrated]} memory trace(s) to long-term storage"
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
    end
  end
end
