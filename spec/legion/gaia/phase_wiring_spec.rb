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

    it 'contains all 8 dream cycle phases' do
      dream_phases = %i[memory_audit association_walk contradiction_resolution
                        agenda_formation consolidation_commit knowledge_promotion
                        dream_reflection dream_narration]
      dream_phases.each do |phase|
        expect(described_class::PHASE_MAP).to have_key(phase)
      end
    end

    it 'has 24 total phases' do
      expect(described_class::PHASE_MAP.size).to eq(24)
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

    it 'returns array of results when multiple handlers match for a phase' do
      mod_a = Module.new do
        def detect_gaps(**)
          { gaps: [] }
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
      expect(result).to be_an(Array)
      expect(result.size).to eq(2)
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
end
