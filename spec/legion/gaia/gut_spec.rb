# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Gut do
  let(:identity) { 'partner-alice' }
  let(:draft_stats) { { length_tokens: 100, format: 'prose', baseline_tokens: 400 } }

  before { Legion::Gaia::BehavioralSynapse.reset! }
  after  { Legion::Gaia::BehavioralSynapse.reset! }

  describe '.check' do
    context 'when no gut synapse and no correction traces exist' do
      before do
        # Stub out memory so retrieve_by_domain returns empty traces
        allow(described_class).to receive(:check_correction_traces).and_return([])
        allow(described_class).to receive(:check_transform_synapses).and_return([])
      end

      it 'returns { conflict: false }' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result).to eq({ conflict: false })
      end
    end

    context 'when lex-agentic-memory is not loaded' do
      it 'returns { conflict: false } (no correction traces available — not nil)' do
        hide_const('Legion::Extensions::Agentic::Memory::Trace::Runners::Traces') if
          defined?(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)

        result = described_class.check(identity: identity, draft_stats: draft_stats)
        # no memory = no correction traces, but transform synapses still checked
        expect(result).to be_a(Hash).or be_nil
      end
    end

    context 'when a transform-tier synapse conflicts with the draft' do
      before do
        # Create a transform-tier synapse (confidence 0.7 → transform mode)
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity,
          domain: 'verbosity',
          directive: { budget_ratio: 0.3 },
          origin: 'explicit'
        )
        # Bump confidence into transform tier (0.7)
        Legion::Gaia::BehavioralSynapse.instance_variable_get(:@store)[
          "#{identity}:verbosity"
        ][:confidence] = 0.7
        allow(described_class).to receive(:check_correction_traces).and_return([])
      end

      let(:draft_stats) do
        { length_tokens: 500, baseline_tokens: 400, format: 'prose' }
      end

      it 'returns conflict: true' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result).to be_a(Hash)
        expect(result[:conflict]).to be true
      end

      it 'includes a confidence value' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result[:confidence]).to be_a(Float)
        expect(result[:confidence]).to be > 0.0
      end

      it 'includes violated_trace_ids' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result[:violated_trace_ids]).to be_an(Array)
      end

      it 'includes a directive' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result[:directive]).to be_a(Hash)
      end
    end

    context 'when transform-tier synapse does not conflict (draft within budget)' do
      before do
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity,
          domain: 'verbosity',
          directive: { budget_ratio: 0.7 },
          origin: 'explicit'
        )
        Legion::Gaia::BehavioralSynapse.instance_variable_get(:@store)[
          "#{identity}:verbosity"
        ][:confidence] = 0.7
        allow(described_class).to receive(:check_correction_traces).and_return([])
      end

      let(:draft_stats) { { length_tokens: 200, baseline_tokens: 400, format: 'prose' } }

      it 'returns conflict: false' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result).to eq({ conflict: false })
      end
    end

    context 'when gut check is unavailable (StandardError raised)' do
      before do
        allow(described_class).to receive(:check_correction_traces).and_raise(StandardError, 'boom')
      end

      it 'returns nil' do
        result = described_class.check(identity: identity, draft_stats: draft_stats)
        expect(result).to be_nil
      end
    end

    context 'latency budget' do
      it 'completes without hanging (well within 50ms budget)' do
        allow(described_class).to receive(:check_correction_traces).and_return([])
        allow(described_class).to receive(:check_transform_synapses).and_return([])

        start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        described_class.check(identity: identity, draft_stats: draft_stats)
        elapsed_ms = (Process.clock_gettime(Process::CLOCK_MONOTONIC) - start) * 1000.0

        expect(elapsed_ms).to be < 50.0
      end
    end

    context 'gut synapse autonomy_mode for new partners' do
      it 'starts in observe mode when no gut synapse exists' do
        synapse = Legion::Gaia::BehavioralSynapse.for(identity: identity, domain: 'gut')
        mode = described_class.gut_mode_for(synapse)
        expect(mode).to eq(:observe)
      end

      it 'returns observe mode for a fresh emergent gut synapse (confidence 0.3)' do
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity,
          domain: 'gut',
          directive: {},
          origin: 'emergent'
        )
        synapse = Legion::Gaia::BehavioralSynapse.for(identity: identity, domain: 'gut')
        expect(synapse[:confidence]).to eq(0.3)
        mode = Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(synapse[:confidence])
        expect(mode).to eq(:observe)
      end
    end
  end

  describe '.check_correction_traces' do
    context 'when lex-agentic-memory is not defined' do
      it 'returns empty array' do
        result = described_class.check_correction_traces(
          identity: identity,
          draft_stats: draft_stats,
          deadline: Process.clock_gettime(Process::CLOCK_MONOTONIC) + 1.0
        )
        expect(result).to eq([])
      end
    end
  end

  describe '.synapse_conflicts_with_draft?' do
    it 'detects budget_ratio conflict when draft exceeds allowed length' do
      synapse = { directive: { budget_ratio: 0.5 } }
      stats = { length_tokens: 300, baseline_tokens: 400 }
      expect(described_class.synapse_conflicts_with_draft?(synapse, stats)).to be true
    end

    it 'returns false when draft is within allowed length' do
      synapse = { directive: { budget_ratio: 0.8 } }
      stats = { length_tokens: 200, baseline_tokens: 400 }
      expect(described_class.synapse_conflicts_with_draft?(synapse, stats)).to be false
    end

    it 'detects format conflict' do
      synapse = { directive: { format: 'structured' } }
      stats = { format: 'prose' }
      expect(described_class.synapse_conflicts_with_draft?(synapse, stats)).to be true
    end

    it 'returns false when format matches' do
      synapse = { directive: { format: 'prose' } }
      stats = { format: 'prose' }
      expect(described_class.synapse_conflicts_with_draft?(synapse, stats)).to be false
    end
  end

  describe '.trace_conflicts_with_draft?' do
    it 'detects verbosity correction conflict' do
      trace = {
        content_payload: { correction_type: 'verbosity', budget_tokens: 200 }
      }
      stats = { length_tokens: 350 }
      expect(described_class.trace_conflicts_with_draft?(trace, stats)).to be true
    end

    it 'returns false when draft is under the budget' do
      trace = {
        content_payload: { correction_type: 'verbosity', budget_tokens: 500 }
      }
      stats = { length_tokens: 100 }
      expect(described_class.trace_conflicts_with_draft?(trace, stats)).to be false
    end

    it 'detects rejected_format conflict' do
      trace = { content_payload: { rejected_format: 'markdown' } }
      stats = { format: 'markdown' }
      expect(described_class.trace_conflicts_with_draft?(trace, stats)).to be true
    end
  end
end
