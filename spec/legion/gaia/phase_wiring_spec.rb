# frozen_string_literal: true

RSpec.describe Legion::Gaia::PhaseWiring do
  describe 'PHASE_MAP' do
    it 'is a frozen hash' do
      expect(described_class::PHASE_MAP).to be_frozen
    end

    it 'contains all 13 active tick phases' do
      active_phases = %i[sensory_processing emotional_evaluation memory_retrieval
                         knowledge_retrieval identity_entropy_check working_memory_integration
                         procedural_check prediction_engine mesh_interface gut_instinct
                         action_selection memory_consolidation post_tick_reflection]
      active_phases.each do |phase|
        expect(described_class::PHASE_MAP).to have_key(phase)
      end
    end

    it 'contains all 7 dream cycle phases' do
      dream_phases = %i[memory_audit association_walk contradiction_resolution
                        agenda_formation consolidation_commit dream_reflection
                        dream_narration]
      dream_phases.each do |phase|
        expect(described_class::PHASE_MAP).to have_key(phase)
      end
    end

    it 'has 20 total phases' do
      expect(described_class::PHASE_MAP.size).to eq(20)
    end

    it 'each mapping has ext, runner, and fn keys' do
      described_class::PHASE_MAP.each_value do |mapping|
        expect(mapping).to have_key(:ext)
        expect(mapping).to have_key(:runner)
        expect(mapping).to have_key(:fn)
      end
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
  end

  describe '.discover_available_extensions' do
    it 'returns a hash of extension availability' do
      discovery = described_class.discover_available_extensions
      expect(discovery).to be_a(Hash)
      expect(discovery.values.first).to have_key(:loaded)
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
end
