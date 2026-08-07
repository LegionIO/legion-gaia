# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Anticipation do
  let(:identity) { 'partner-alice' }
  let(:context)  { { rag_entry_count: 20 } }

  describe '.build' do
    context 'when lex-agentic-inference is not loaded' do
      before do
        allow(described_class).to receive(:inference_available?).and_return(false)
      end

      it 'returns nil' do
        result = described_class.build(identity: identity, context: context)
        expect(result).to be_nil
      end
    end

    context 'when inference is available but no pending predictions' do
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(mock_runner).to receive(:pending_predictions).and_return({ predictions: [], count: 0 })
      end

      it 'returns nil' do
        result = described_class.build(identity: identity, context: context)
        expect(result).to be_nil
      end
    end

    context 'when inference is available with an actionable prediction' do
      let(:prediction_id) { 'pred-uuid-1234' }
      let(:prediction) do
        {
          prediction_id: prediction_id,
          mode: :question,
          confidence: 0.75,
          description: 'Partner will ask about deployment',
          status: :pending,
          created_at: Time.now.utc,
          emotional_context: nil,
          context: {}
        }
      end
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(mock_runner).to receive(:pending_predictions).and_return({ predictions: [prediction], count: 1 })
        allow(described_class).to receive(:deferred?).and_return(false)
      end

      it 'returns a hash with prediction_id' do
        result = described_class.build(identity: identity, context: context)
        expect(result).to be_a(Hash)
        expect(result[:prediction_id]).to eq(prediction_id)
      end

      it 'includes content' do
        result = described_class.build(identity: identity, context: context)
        expect(result[:content]).to be_a(String)
      end

      it 'includes confidence' do
        result = described_class.build(identity: identity, context: context)
        expect(result[:confidence]).to be_a(Float)
        expect(result[:confidence]).to eq(0.75)
      end

      it 'includes pre_staged array' do
        result = described_class.build(identity: identity, context: context)
        expect(result[:pre_staged]).to be_an(Array)
      end
    end

    context 'with negative-valence anticipation and low affect baseline' do
      let(:prediction_id) { 'pred-negative-1' }
      let(:negative_prediction) do
        {
          prediction_id: prediction_id,
          mode: :question,
          confidence: 0.80,
          description: 'Conflict likely',
          status: :pending,
          created_at: Time.now.utc,
          emotional_context: { valence: -0.6 },
          context: {}
        }
      end
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(mock_runner).to receive(:pending_predictions).and_return({ predictions: [negative_prediction], count: 1 })
        allow(described_class).to receive(:affect_baseline_low?).and_return(true)
      end

      it 'returns nil (deferred)' do
        result = described_class.build(identity: identity, context: context)
        expect(result).to be_nil
      end
    end

    context 'with negative-valence anticipation but neutral affect baseline' do
      let(:prediction_id) { 'pred-negative-2' }
      let(:negative_prediction) do
        {
          prediction_id: prediction_id,
          mode: :question,
          confidence: 0.80,
          description: 'Might ask about errors',
          status: :pending,
          created_at: Time.now.utc,
          emotional_context: { valence: -0.3 },
          context: {}
        }
      end
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(mock_runner).to receive(:pending_predictions).and_return({ predictions: [negative_prediction], count: 1 })
        allow(described_class).to receive(:affect_baseline_low?).and_return(false)
      end

      it 'returns the anticipation (not deferred)' do
        result = described_class.build(identity: identity, context: context)
        expect(result).to be_a(Hash)
        expect(result[:prediction_id]).to eq(prediction_id)
      end
    end

    context 'pre-staging cap at 25% of RAG entries' do
      let(:prediction_id) { 'pred-prestage-1' }
      let(:pre_stage_entries) { (1..10).map { |i| { entry_id: "e#{i}" } } }
      let(:prediction) do
        {
          prediction_id: prediction_id,
          mode: :question,
          confidence: 0.75,
          description: 'About testing',
          status: :pending,
          created_at: Time.now.utc,
          emotional_context: nil,
          context: { pre_stage_entries: pre_stage_entries }
        }
      end
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(mock_runner).to receive(:pending_predictions).and_return({ predictions: [prediction], count: 1 })
        allow(described_class).to receive(:deferred?).and_return(false)
      end

      it 'caps pre-staged entries at 25% of rag_entry_count' do
        ctx = { rag_entry_count: 20 }
        result = described_class.build(identity: identity, context: ctx)
        # 25% of 20 = 5
        expect(result[:pre_staged].size).to be <= 5
      end

      it 'never exceeds the cap' do
        ctx = { rag_entry_count: 4 }
        result = described_class.build(identity: identity, context: ctx)
        # 25% of 4 = 1
        expect(result[:pre_staged].size).to be <= 1
      end
    end
  end

  describe '.resolve' do
    context 'when lex-agentic-inference is not loaded' do
      before do
        allow(described_class).to receive(:inference_available?).and_return(false)
      end

      it 'returns nil' do
        result = described_class.resolve(identity: identity, prediction_id: 'pred-1', actual: 'some input')
        expect(result).to be_nil
      end
    end

    context 'when inference is available' do
      let(:prediction_id) { 'pred-resolve-1' }
      let(:mock_runner) { double('prediction_runner') }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:inference_runner).and_return(mock_runner)
        allow(described_class).to receive(:high_entropy?).and_return(false)
        allow(mock_runner).to receive(:get_prediction).with(prediction_id: prediction_id, identity: identity)
                                                      .and_return({ found: false })
        allow(mock_runner).to receive(:resolve_prediction).and_return({ resolved: true, outcome: :incorrect })
      end

      it 'resolves and returns a result hash' do
        result = described_class.resolve(identity: identity, prediction_id: prediction_id,
                                         actual: 'something unrelated')
        expect(result).to be_a(Hash)
      end
    end

    context 'under high entropy' do
      let(:prediction_id) { 'pred-entropy-1' }

      before do
        allow(described_class).to receive(:inference_available?).and_return(true)
        allow(described_class).to receive(:high_entropy?).and_return(true)
      end

      it 'skips resolution and returns not-resolved' do
        result = described_class.resolve(identity: identity, prediction_id: prediction_id,
                                         actual: 'some input')
        expect(result[:resolved]).to be false
        expect(result[:reason]).to eq(:high_entropy)
      end
    end
  end

  describe '.deferred?' do
    context 'when anticipation has no emotional context' do
      it 'returns false' do
        anticipation = { prediction_id: 'p1', confidence: 0.7 }
        expect(described_class.deferred?(identity: identity, anticipation: anticipation)).to be false
      end
    end

    context 'when anticipation has positive valence' do
      it 'returns false' do
        anticipation = { prediction_id: 'p1', confidence: 0.7, emotional_context: { valence: 0.5 } }
        expect(described_class.deferred?(identity: identity, anticipation: anticipation)).to be false
      end
    end

    context 'when anticipation has negative valence and affect baseline is low' do
      before do
        allow(described_class).to receive(:affect_baseline_low?).and_return(true)
      end

      it 'returns true' do
        anticipation = { prediction_id: 'p1', confidence: 0.7, emotional_context: { valence: -0.5 } }
        expect(described_class.deferred?(identity: identity, anticipation: anticipation)).to be true
      end
    end

    context 'when anticipation has negative valence but affect baseline is not low' do
      before do
        allow(described_class).to receive(:affect_baseline_low?).and_return(false)
      end

      it 'returns false' do
        anticipation = { prediction_id: 'p1', confidence: 0.7, emotional_context: { valence: -0.4 } }
        expect(described_class.deferred?(identity: identity, anticipation: anticipation)).to be false
      end
    end
  end

  describe '.grade_prediction' do
    before do
      allow(described_class).to receive(:inference_available?).and_return(false)
    end

    it 'returns :incorrect when inference not available' do
      result = described_class.grade_prediction(prediction_id: 'p1', actual: 'foo', identity: identity)
      expect(result).to eq(:incorrect)
    end
  end

  describe '.partial_match?' do
    it 'returns true when majority of words overlap' do
      expect(described_class.partial_match?('deploy the service', 'how to deploy the service')).to be true
    end

    it 'returns false when no words overlap' do
      expect(described_class.partial_match?('running tests', 'check the logs')).to be false
    end
  end

  describe '.build_prestaged' do
    it 'returns empty when context has no rag_entry_count' do
      result = described_class.build_prestaged(context: {}, prediction: {})
      expect(result).to eq([])
    end

    it 'returns empty when prediction context has no pre_stage_entries' do
      result = described_class.build_prestaged(
        context: { rag_entry_count: 10 },
        prediction: { context: {} }
      )
      expect(result).to eq([])
    end

    it 'returns capped entries from prediction context' do
      entries = (1..10).map { |i| { id: i } }
      result = described_class.build_prestaged(
        context: { rag_entry_count: 8 },
        prediction: { context: { pre_stage_entries: entries } }
      )
      # 25% of 8 = 2
      expect(result.size).to be <= 2
    end
  end
end
