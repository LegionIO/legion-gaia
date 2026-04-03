# frozen_string_literal: true

RSpec.describe Legion::Gaia::PhaseWiring do
  describe 'PHASE_MAP' do
    it 'is a frozen hash' do
      expect(described_class::PHASE_MAP).to be_frozen
    end

    it 'contains all 16 active tick phases' do
      active_phases = %i[sensory_processing emotional_evaluation memory_retrieval
                         knowledge_retrieval identity_entropy_check working_memory_integration
                         procedural_check prediction_engine mesh_interface
                         social_cognition theory_of_mind gut_instinct
                         action_selection memory_consolidation homeostasis_regulation
                         post_tick_reflection]
      active_phases.each do |phase|
        expect(described_class::PHASE_MAP).to have_key(phase)
      end
    end

    it 'contains all 9 dream cycle phases' do
      dream_phases = %i[memory_audit association_walk contradiction_resolution
                        agenda_formation consolidation_commit knowledge_promotion
                        dream_reflection partner_reflection dream_narration]
      dream_phases.each do |phase|
        expect(described_class::PHASE_MAP).to have_key(phase)
      end
    end

    it 'has 25 total phases' do
      expect(described_class::PHASE_MAP.size).to eq(25)
    end

    it 'each mapping has ext, runner, and fn keys' do
      described_class::PHASE_MAP.each_value do |value|
        described_class.mappings_for(value).each do |mapping|
          expect(mapping).to have_key(:ext)
          expect(mapping).to have_key(:runner)
          expect(mapping).to have_key(:fn)
        end
      end
    end

    it 'wires synapse gaia_summary into working_memory_integration' do
      value = described_class::PHASE_MAP[:working_memory_integration]
      maps = described_class.mappings_for(value)
      synapse_entry = maps.find { |m| m[:ext] == :Synapse && m[:runner] == :GaiaReport }
      expect(synapse_entry).not_to be_nil
      expect(synapse_entry[:fn]).to eq(:gaia_summary)
    end

    it 'wires synapse gaia_reflection into post_tick_reflection' do
      value = described_class::PHASE_MAP[:post_tick_reflection]
      maps = described_class.mappings_for(value)
      synapse_entry = maps.find { |m| m[:ext] == :Synapse && m[:runner] == :GaiaReport }
      expect(synapse_entry).not_to be_nil
      expect(synapse_entry[:fn]).to eq(:gaia_reflection)
    end

    it 'preserves primary handler in working_memory_integration' do
      value = described_class::PHASE_MAP[:working_memory_integration]
      maps = described_class.mappings_for(value)
      primary = maps.find { |m| m[:ext] == :Curiosity }
      expect(primary).not_to be_nil
      expect(primary[:fn]).to eq(:detect_gaps)
    end

    it 'preserves primary handler in post_tick_reflection' do
      value = described_class::PHASE_MAP[:post_tick_reflection]
      maps = described_class.mappings_for(value)
      primary = maps.find { |m| m[:ext] == :Reflection }
      expect(primary).not_to be_nil
      expect(primary[:fn]).to eq(:reflect)
    end
  end

  describe 'PHASE_ARGS' do
    it 'is a frozen hash' do
      expect(described_class::PHASE_ARGS).to be_frozen
    end

    it 'has an entry for every phase in PHASE_MAP' do
      described_class::PHASE_MAP.each_key do |phase|
        expect(described_class::PHASE_ARGS).to have_key(phase),
                                               "Missing PHASE_ARGS entry for #{phase}"
      end
    end

    it 'each entry is callable' do
      described_class::PHASE_ARGS.each_value do |builder|
        expect(builder).to respond_to(:call)
      end
    end

    it 'marks memory_consolidation as deferred maintenance on the heartbeat path' do
      expect(described_class::PHASE_ARGS[:memory_consolidation].call({})).to eq({ maintenance: false })
    end

    it 'skips memory_retrieval when no signals are present' do
      expect(described_class::PHASE_ARGS[:memory_retrieval].call(signals: [])).to eq(
        { skip: true, reason: :idle_no_signals }
      )
    end

    it 'runs memory_retrieval when signals are present' do
      result = described_class::PHASE_ARGS[:memory_retrieval].call(signals: [{ value: 'ping' }])
      expect(result).to include(:limit)
    end

    it 'uses signal value for knowledge_retrieval text' do
      result = described_class::PHASE_ARGS[:knowledge_retrieval].call(
        signals: [{ value: 'testing', source_type: :human_direct, tags: [:api] }],
        prior_results: {}
      )

      expect(result).to include(text: 'testing', tags: [:api])
    end

    it 'skips prediction_engine when no signals are present' do
      expect(described_class::PHASE_ARGS[:prediction_engine].call(signals: [])).to eq(
        { skip: true, reason: :idle_no_signals }
      )
    end

    it 'runs prediction_engine when signals are present' do
      result = described_class::PHASE_ARGS[:prediction_engine].call(
        signals: [{ value: 'testing' }],
        prior_results: { emotional_evaluation: { arousal: 0.2 } }
      )

      expect(result).to eq(
        mode: :functional_mapping,
        context: { emotional_evaluation: { arousal: 0.2 } }
      )
    end
  end

  describe '.resolve_runner_class' do
    it 'returns nil for missing extensions' do
      expect(described_class.resolve_runner_class(:Nonexistent, :Foo)).to be_nil
    end

    context 'when core library module exists at Legion:: namespace' do
      before do
        stub_const('Legion::Apollo', Module.new)
        stub_const('Legion::Apollo::Runners', Module.new)
        stub_const('Legion::Apollo::Runners::Request', Class.new)
      end

      it 'resolves from core namespace first' do
        result = described_class.resolve_runner_class(:Apollo, :Request)
        expect(result).to eq(Legion::Apollo::Runners::Request)
      end
    end

    context 'when core library exists but requested runner does not' do
      before do
        stub_const('Legion::Apollo', Module.new)
        stub_const('Legion::Apollo::Runners', Module.new)
      end

      it 'falls through to extensions namespace' do
        result = described_class.resolve_runner_class(:Apollo, :Nonexistent)
        expect(result).to be_nil
      end
    end
  end

  describe '.discover_available_extensions' do
    it 'returns a hash of extension availability' do
      discovery = described_class.discover_available_extensions
      expect(discovery).to be_a(Hash)
      expect(discovery.values.first).to have_key(:loaded)
    end
  end

  describe '.mappings_for' do
    it 'wraps a single hash in an array' do
      mapping = { ext: :Foo, runner: :Bar, fn: :baz }
      expect(described_class.mappings_for(mapping)).to eq([mapping])
    end

    it 'returns an array unchanged' do
      mappings = [{ ext: :Foo, runner: :Bar, fn: :baz }, { ext: :Qux, runner: :Qux, fn: :qux }]
      expect(described_class.mappings_for(mappings)).to eq(mappings)
    end
  end

  describe '.build_phase_handlers' do
    it 'returns empty hash when no runner instances match' do
      handlers = described_class.build_phase_handlers({})
      expect(handlers).to eq({})
    end

    it 'builds handler for matching runner instance' do
      test_module = Module.new do
        def filter_signals(**)
          { filtered: true }
        end
      end
      host = Legion::Gaia::RunnerHost.new(test_module)
      instances = { Attention_Attention: host }

      handlers = described_class.build_phase_handlers(instances)
      expect(handlers).to have_key(:sensory_processing)
      expect(handlers[:sensory_processing]).to respond_to(:call)
    end

    it 'returns single result directly when only one handler matches' do
      test_module = Module.new do
        def filter_signals(**)
          { filtered: true }
        end
      end
      host = Legion::Gaia::RunnerHost.new(test_module)
      instances = { Attention_Attention: host }

      handlers = described_class.build_phase_handlers(instances)
      result = handlers[:sensory_processing].call(state: {}, signals: [], prior_results: {})
      expect(result).to eq({ filtered: true })
    end

    it 'coalesces multi-handler hash results into a single hash for a phase' do
      mod_a = Module.new do
        def detect_gaps(**)
          { curiosity_intensity: 0.7 }
        end
      end
      mod_b = Module.new do
        def gaia_summary(**)
          { health_score: 1.0 }
        end
      end
      host_a = Legion::Gaia::RunnerHost.new(mod_a)
      host_b = Legion::Gaia::RunnerHost.new(mod_b)
      instances = { Curiosity_Curiosity: host_a, Synapse_GaiaReport: host_b }

      handlers = described_class.build_phase_handlers(instances)
      expect(handlers).to have_key(:working_memory_integration)
      result = handlers[:working_memory_integration].call(state: {}, signals: [], prior_results: {})
      expect(result).to eq({ curiosity_intensity: 0.7, health_score: 1.0 })
    end

    it 'wires a phase when only the synapse handler is present' do
      test_module = Module.new do
        def gaia_summary(**)
          { health_score: 0.9 }
        end
      end
      host = Legion::Gaia::RunnerHost.new(test_module)
      instances = { Synapse_GaiaReport: host }

      handlers = described_class.build_phase_handlers(instances)
      expect(handlers).to have_key(:working_memory_integration)
    end

    it 'treats skip args as phase control flow and does not invoke the runner' do
      test_module = Module.new do
        def retrieve(**)
          raise 'runner should not be called'
        end
      end
      host = Legion::Gaia::RunnerHost.new(test_module)
      instances = { Apollo_Request: host }

      handlers = described_class.build_phase_handlers(instances)
      result = handlers[:knowledge_retrieval].call(state: {}, signals: [], prior_results: {})

      expect(result).to eq({ status: :skipped, reason: :phase_wiring_skip })
    end

    it 'passes normalized prior results to downstream single-handler phases' do
      test_module = Module.new do
        def form_intentions(tick_results:, **)
          tick_results[:working_memory_integration]
        end
      end
      host = Legion::Gaia::RunnerHost.new(test_module)
      instances = { Volition_Volition: host }

      handlers = described_class.build_phase_handlers(instances)
      prior_results = {
        working_memory_integration: [
          { curiosity_intensity: 0.8 },
          { health_score: 0.95 }
        ]
      }
      result = handlers[:action_selection].call(state: {}, signals: [], prior_results: prior_results)

      expect(result).to eq({ curiosity_intensity: 0.8, health_score: 0.95 })
    end
  end

  describe '.collect_valences' do
    it 'returns empty array for nil' do
      expect(described_class.collect_valences(nil)).to eq([])
    end

    it 'returns empty array when no emotional_evaluation' do
      expect(described_class.collect_valences({})).to eq([])
    end

    it 'extracts valence from emotional_evaluation result' do
      valence = { urgency: 0.5, importance: 0.3, novelty: 0.2, familiarity: 0.8 }
      results = { emotional_evaluation: { valence: valence } }
      expect(described_class.collect_valences(results)).to eq([valence])
    end
  end

  describe '.build_promotion_content' do
    it 'returns nil when no dream phases produced results' do
      expect(described_class.build_promotion_content({})).to be_nil
    end

    it 'extracts association walk results' do
      results = { association_walk: { linked: true, trace_id_a: 'a1', trace_id_b: 'b2' } }
      content = described_class.build_promotion_content(results)
      expect(content).to include('Association: linked trace a1 to b2')
    end

    it 'extracts contradiction resolution counts' do
      results = { contradiction_resolution: { resolved: 3 } }
      content = described_class.build_promotion_content(results)
      expect(content).to include('Resolved 3 contradiction(s)')
    end

    it 'extracts consolidation migration counts' do
      results = { consolidation_commit: { migrated: 5 } }
      content = described_class.build_promotion_content(results)
      expect(content).to include('Consolidated 5 memory trace(s)')
    end

    it 'extracts dream reflection insights' do
      results = { dream_reflection: { insight: 'Pattern detected in deployment failures' } }
      content = described_class.build_promotion_content(results)
      expect(content).to include('Insight: Pattern detected in deployment failures')
    end

    it 'extracts agenda formation items' do
      results = { agenda_formation: { agenda: [{ question: 'Why did deploy fail?' }, { topic: 'scaling' }] } }
      content = described_class.build_promotion_content(results)
      expect(content).to include('Agenda: Why did deploy fail?; scaling')
    end

    it 'combines multiple dream phase results' do
      results = {
        association_walk: { linked: true, trace_id_a: 'x', trace_id_b: 'y' },
        contradiction_resolution: { resolved: 1 },
        dream_reflection: { insight: 'Systems are correlated' }
      }
      content = described_class.build_promotion_content(results)
      expect(content).to start_with('Dream cycle synthesis:')
      expect(content).to include('Association:')
      expect(content).to include('Resolved 1')
      expect(content).to include('Insight:')
    end

    it 'skips phases with zero or missing counts' do
      results = { contradiction_resolution: { resolved: 0 }, consolidation_commit: {} }
      expect(described_class.build_promotion_content(results)).to be_nil
    end
  end

  describe 'PHASE_ARGS human_observations' do
    it 'prefers top-level partner_observations from tick execution context' do
      args_lambda = described_class::PHASE_ARGS[:social_cognition]
      ctx = {
        prior_results: { memory: :data },
        partner_observations: [{ identity: 'top-level' }],
        state: Object.new,
        signals: [],
        current_signal: nil,
        valences: {}
      }
      result = args_lambda.call(ctx)
      expect(result[:human_observations]).to eq([{ identity: 'top-level' }])
    end

    it 'passes human_observations to social_cognition' do
      args_lambda = described_class::PHASE_ARGS[:social_cognition]
      ctx = { prior_results: { memory: :data }, state: { partner_observations: [{ identity: 'esity' }] },
              signals: [], current_signal: nil, valences: {} }
      result = args_lambda.call(ctx)
      expect(result[:human_observations]).to eq([{ identity: 'esity' }])
      expect(result[:tick_results]).to eq({ memory: :data })
    end

    it 'passes human_observations to theory_of_mind' do
      args_lambda = described_class::PHASE_ARGS[:theory_of_mind]
      ctx = { prior_results: {}, state: { partner_observations: [{ identity: 'esity' }] },
              signals: [], current_signal: nil, valences: {} }
      result = args_lambda.call(ctx)
      expect(result[:human_observations]).to eq([{ identity: 'esity' }])
    end

    it 'passes human_observations to emotional_evaluation' do
      args_lambda = described_class::PHASE_ARGS[:emotional_evaluation]
      ctx = { prior_results: {}, state: { partner_observations: [{ identity: 'esity' }] },
              signals: [], current_signal: nil, valences: {} }
      result = args_lambda.call(ctx)
      expect(result[:human_observations]).to eq([{ identity: 'esity' }])
    end

    it 'defaults to empty array when no observations' do
      args_lambda = described_class::PHASE_ARGS[:social_cognition]
      ctx = { prior_results: {}, state: {}, signals: [], current_signal: nil, valences: {} }
      result = args_lambda.call(ctx)
      expect(result[:human_observations]).to eq([])
    end
  end

  describe 'PHASE_ARGS observer cursor' do
    it 'prefers top-level last_observer_tick from tick execution context' do
      args_lambda = described_class::PHASE_ARGS[:post_tick_reflection]
      ctx = {
        prior_results: {},
        last_observer_tick: 42,
        state: Object.new
      }
      result = args_lambda.call(ctx)
      expect(result[:since]).to eq(42)
    end
  end

  describe 'PHASE_ARGS knowledge_promotion' do
    let(:builder) { described_class::PHASE_ARGS[:knowledge_promotion] }

    it 'returns skip when no dream insights exist' do
      ctx = { prior_results: {} }
      result = builder.call(ctx)
      expect(result).to eq({ skip: true })
    end

    it 'builds content from prior dream results' do
      ctx = { prior_results: { dream_reflection: { insight: 'test insight' } } }
      result = builder.call(ctx)
      expect(result[:content]).to include('test insight')
      expect(result[:content_type]).to eq(:observation)
      expect(result[:tags]).to include('dream_cycle')
      expect(result[:source_agent]).to eq('gaia')
    end
  end

  describe 'action_selection PHASE_ARGS includes bond_state' do
    it 'passes bond_state from partner_reflection' do
      ctx = { prior_results: { partner_reflection: { partner_bond: { stage: :established } } } }
      args = described_class::PHASE_ARGS[:action_selection].call(ctx)
      expect(args).to have_key(:bond_state)
      expect(args[:bond_state][:partner_bond][:stage]).to eq(:established)
    end

    it 'defaults bond_state to empty hash' do
      ctx = { prior_results: {} }
      args = described_class::PHASE_ARGS[:action_selection].call(ctx)
      expect(args[:bond_state]).to eq({})
    end

    it 'extracts first hash from partner_reflection array when multi-handler result' do
      bond_result = { partner_bond: { stage: :established } }
      ctx = { prior_results: { partner_reflection: [bond_result, { synced: true }] } }
      args = described_class::PHASE_ARGS[:action_selection].call(ctx)
      expect(args[:bond_state]).to eq(bond_result)
    end

    it 'falls back to live attachment reflection when prior partner_reflection is absent' do
      runner = instance_double('AttachmentRunner')
      registry = instance_double('Legion::Gaia::Registry', runner_instances: { Social_Attachment: runner })
      allow(Legion::Gaia).to receive(:registry).and_return(registry)
      allow(runner).to receive(:reflect_on_bonds)
        .with(tick_results: { prediction_engine: { confidence: 0.7 } }, bond_summary: {})
        .and_return({ partner_bond: { absence_exceeds_pattern: true } })

      ctx = { prior_results: { prediction_engine: { confidence: 0.7 } } }
      args = described_class::PHASE_ARGS[:action_selection].call(ctx)

      expect(args[:bond_state]).to eq({ partner_bond: { absence_exceeds_pattern: true } })
    end
  end

  describe 'partner_reflection phase' do
    it 'exists in PHASE_MAP' do
      expect(described_class::PHASE_MAP).to have_key(:partner_reflection)
    end

    it 'targets Social Attachment runner' do
      entry = described_class::PHASE_MAP[:partner_reflection]
      bond_handler = entry.is_a?(Array) ? entry.find { |h| h[:fn] == :reflect_on_bonds } : entry
      expect(bond_handler[:ext]).to eq(:Social)
      expect(bond_handler[:runner]).to eq(:Attachment)
      expect(bond_handler[:fn]).to eq(:reflect_on_bonds)
    end

    it 'has PHASE_ARGS lambda' do
      expect(described_class::PHASE_ARGS).to have_key(:partner_reflection)
      expect(described_class::PHASE_ARGS[:partner_reflection]).to respond_to(:call)
    end

    it 'PHASE_ARGS returns tick_results and bond_summary' do
      ctx = { prior_results: { dream_reflection: { insight: 'test' } } }
      args = described_class::PHASE_ARGS[:partner_reflection].call(ctx)
      expect(args).to have_key(:tick_results)
      expect(args).to have_key(:bond_summary)
      expect(args[:bond_summary]).to eq({ insight: 'test' })
    end

    it 'PHASE_ARGS handles nil prior_results' do
      ctx = { prior_results: nil }
      args = described_class::PHASE_ARGS[:partner_reflection].call(ctx)
      expect(args[:tick_results]).to eq({})
      expect(args[:bond_summary]).to eq({})
    end
  end
end
