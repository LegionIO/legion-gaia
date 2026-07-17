# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::PartnerModel do
  let(:identity) { 'test-partner' }

  def make_synapse(domain:, confidence:, emotional_intensity: 0.0, directive: 'do something', id: nil)
    {
      id: id || SecureRandom.uuid,
      identity: identity,
      domain: domain,
      confidence: confidence,
      emotional_intensity: emotional_intensity,
      directive: directive,
      origin: 'explicit',
      status: 'active'
    }
  end

  def make_trace(strength:, emotional_intensity: 0.5, domain_tags: ['partner_interaction'], trace_id: nil,
                 content_payload: {})
    {
      trace_id: trace_id || SecureRandom.uuid,
      strength: strength,
      emotional_intensity: emotional_intensity,
      domain_tags: domain_tags,
      content_payload: content_payload
    }
  end

  def make_preference(source:, domain: 'style', content: 'be concise', id: nil)
    { id: id || SecureRandom.uuid, source: source, domain: domain, content: content }
  end

  # ---------------------------------------------------------------------------
  # Slot count basics
  # ---------------------------------------------------------------------------

  describe '.build — slot count' do
    context 'with 7 transform-tier synapses (confidence 0.7)' do
      let(:synapses) do
        7.times.map { |i| make_synapse(domain: "domain_#{i}", confidence: 0.7) }
      end

      it 'returns all 7 slots' do
        result = described_class.build(identity: identity, synapses: synapses)
        expect(result.size).to eq(7)
      end
    end

    context 'with 10 transform-tier synapses' do
      let(:synapses) do
        10.times.map { |i| make_synapse(domain: "domain_#{i}", confidence: 0.7) }
      end

      it 'returns only 7 slots (hard cap)' do
        result = described_class.build(identity: identity, synapses: synapses)
        expect(result.size).to eq(7)
      end
    end

    context 'with 7 observe-tier + 3 transform-tier synapses' do
      let(:synapses) do
        observe = 7.times.map { |i| make_synapse(domain: "obs_#{i}", confidence: 0.1) }
        transform = 3.times.map { |i| make_synapse(domain: "xform_#{i}", confidence: 0.7) }
        observe + transform
      end

      it 'returns only 3 slots (observe excluded)' do
        result = described_class.build(identity: identity, synapses: synapses)
        expect(result.size).to eq(3)
      end

      it 'all returned slots are not observe-mode' do
        result = described_class.build(identity: identity, synapses: synapses)
        modes = result.map { |s| s[:autonomy_mode] }
        expect(modes).not_to include(:observe)
      end
    end

    context 'with zero transform/filter/autonomous synapses (only observe)' do
      let(:synapses) do
        5.times.map { |i| make_synapse(domain: "obs_#{i}", confidence: 0.1) }
      end

      it 'returns empty array' do
        result = described_class.build(identity: identity, synapses: synapses)
        expect(result).to be_empty
      end
    end

    context 'with no synapses, traces, or preferences' do
      it 'returns empty array' do
        result = described_class.build(identity: identity, synapses: [], traces: [], preferences: [])
        expect(result).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  # Mixed-type competition
  # ---------------------------------------------------------------------------

  describe '.build — mixed-type competition' do
    it 'combines synapses, traces, and preferences in one ranking' do
      synapses    = [make_synapse(domain: 'behavior', confidence: 0.75)]
      traces      = [make_trace(strength: 0.8, domain_tags: ['correction'])]
      preferences = [make_preference(source: 'explicit', domain: 'style')]

      result = described_class.build(identity: identity, synapses: synapses,
                                     traces: traces, preferences: preferences)
      types = result.map { |s| s[:type] }
      expect(types).to include(:synapse)
      expect(types).to include(:trace)
      expect(types).to include(:preference)
    end

    it 'ranks all candidates by score (strength * (1 + emotional_intensity)) descending' do
      # high-intensity trace should outrank a lower-scored synapse
      low_synapse  = make_synapse(domain: 'low',  confidence: 0.65, emotional_intensity: 0.0)
      high_trace   = make_trace(strength: 0.65, emotional_intensity: 0.9, domain_tags: ['t'])

      result = described_class.build(identity: identity, synapses: [low_synapse], traces: [high_trace])
      expect(result.first[:type]).to eq(:trace)
    end
  end

  # ---------------------------------------------------------------------------
  # Scoring: higher emotional intensity boosts ranking
  # ---------------------------------------------------------------------------

  describe '.build — scoring' do
    it 'a higher-intensity synapse ranks above an equal-strength lower-intensity one' do
      low_intensity  = make_synapse(domain: 'low',  confidence: 0.72, emotional_intensity: 0.1,
                                    id: 'aaa', directive: 'low')
      high_intensity = make_synapse(domain: 'high', confidence: 0.72, emotional_intensity: 0.9,
                                    id: 'bbb', directive: 'high')

      result = described_class.build(identity: identity, synapses: [low_intensity, high_intensity])
      expect(result.first[:source_id]).to eq('bbb')
    end

    it 'when 10 candidates exist, top 7 by score are selected' do
      synapses = 10.times.map do |i|
        # give each a distinct confidence so scores are ordered
        make_synapse(domain: "d#{i}", confidence: 0.65 + (i * 0.003))
      end

      result = described_class.build(identity: identity, synapses: synapses)
      domains = result.map { |s| s[:domain] }
      # top 7 by score = indices 3..9 (highest confidence)
      expect(domains).to include('d9', 'd8', 'd7', 'd6', 'd5', 'd4', 'd3')
      expect(domains).not_to include('d0', 'd1', 'd2')
    end
  end

  # ---------------------------------------------------------------------------
  # Slot shape
  # ---------------------------------------------------------------------------

  describe '.build — slot structure' do
    let(:synapse) { make_synapse(domain: 'verbosity', confidence: 0.7, directive: 'be brief') }

    it 'returns hashes with required keys' do
      result = described_class.build(identity: identity, synapses: [synapse])
      slot = result.first
      expect(slot.keys).to match_array(%i[type domain content strength source_id autonomy_mode])
    end

    it 'sets autonomy_mode on synapse slots' do
      result = described_class.build(identity: identity, synapses: [synapse])
      expect(result.first[:autonomy_mode]).to eq(:transform)
    end
  end

  # ---------------------------------------------------------------------------
  # observe_mode_entries
  # ---------------------------------------------------------------------------

  describe '.observe_mode_entries' do
    before { Legion::Gaia::BehavioralSynapse.reset! }
    after  { Legion::Gaia::BehavioralSynapse.reset! }

    context 'when observe-tier synapses exist for identity' do
      before do
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity, domain: 'tone', directive: 'be casual', origin: 'explicit'
        )
        # force to observe tier by manually downgrading confidence
        entry = Legion::Gaia::BehavioralSynapse.for(identity: identity, domain: 'tone')
        entry[:confidence] = 0.1 if entry
      end

      it 'returns only observe-tier entries' do
        # pass observe-tier synapses directly (store may differ due to crystallize starting score)
        observe_synapse = make_synapse(domain: 'quiet', confidence: 0.1)
        transform_synapse = make_synapse(domain: 'active', confidence: 0.72)

        allow(Legion::Gaia::BehavioralSynapse).to receive(:all_for).with(identity: identity)
                                                                   .and_return([observe_synapse, transform_synapse])

        result = described_class.observe_mode_entries(identity: identity)
        expect(result.size).to eq(1)
        expect(result.first[:autonomy_mode]).to eq(:observe)
        expect(result.first[:domain]).to eq('quiet')
      end
    end

    context 'when no synapses exist for identity' do
      before do
        allow(Legion::Gaia::BehavioralSynapse).to receive(:all_for).with(identity: identity).and_return([])
      end

      it 'returns empty array' do
        expect(described_class.observe_mode_entries(identity: identity)).to be_empty
      end
    end
  end

  # ---------------------------------------------------------------------------
  # MAX_WORKING_MEMORY_SLOTS setting override
  # ---------------------------------------------------------------------------

  describe 'MAX_WORKING_MEMORY_SLOTS' do
    it 'is 7 by default' do
      expect(described_class::MAX_WORKING_MEMORY_SLOTS).to eq(7)
    end
  end

  describe '.build — respects settings max_slots override' do
    let(:synapses) do
      5.times.map { |i| make_synapse(domain: "d#{i}", confidence: 0.75) }
    end

    it 'caps at settings max_slots when set to 3' do
      allow(Legion::Gaia).to receive(:settings).and_return({ partner_model: { max_slots: 3 } })
      result = described_class.build(identity: identity, synapses: synapses)
      expect(result.size).to eq(3)
    end
  end
end
