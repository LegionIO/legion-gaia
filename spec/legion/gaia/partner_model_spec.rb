# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::PartnerModel do
  let(:identity) { 'alice' }

  def synapse(id:, domain: 'tone', confidence: 0.8, origin: 'emergent', **attributes)
    { id: id, identity: identity, domain: domain, confidence: confidence,
      directive: id, origin: origin, status: 'active' }.merge(attributes)
  end

  def trace(id:, domain: 'tone', content: 'remember this', **attributes)
    { trace_id: id, domain_tags: ["partner:#{identity}", domain], strength: 0.8,
      content_payload: content }.merge(attributes)
  end

  before do
    allow(Legion::Gaia).to receive(:registry).and_return(nil)
    allow(Legion::Gaia).to receive(:calibration_runner_for).and_return(nil)
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::ResponseAttribution.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  after do
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::ResponseAttribution.reset!
  end

  it 'never includes unowned memory or another humans supplied candidates' do
    candidates = [synapse(id: 'mine'), synapse(id: 'theirs', identity: 'bob')]
    traces = [trace(id: 'my-memory'), trace(id: 'private', domain_tags: ['partner:bob']),
              trace(id: 'unowned', domain_tags: [])]
    preferences = [{ owner_id: 'bob', source: :explicit, domain: 'format', content: 'private' }]
    result = described_class.build(identity: identity, synapses: candidates, traces: traces, preferences: preferences)
    expect(result.map { |slot| slot[:source_id] }).to contain_exactly('mine', 'my-memory')
  end

  it 'excludes inactive and observe-tier directives from response instructions' do
    candidates = [synapse(id: 'observe', confidence: 0.1), synapse(id: 'dampened', status: 'dampened'),
                  synapse(id: 'active')]
    result = described_class.build(identity: identity, synapses: candidates)
    expect(result.map { |slot| slot[:source_id] }).to eq(['active'])
  end

  it 'honors explicit preferences over stronger emotional inferred preferences in the same domain' do
    candidates = [synapse(id: 'long', domain: 'verbosity', confidence: 0.99, emotional_intensity: 1.0)]
    preferences = [{ id: 'explicit', owner_id: identity, source: :explicit, domain: 'verbosity', content: 'brief' },
                   { id: 'inferred', owner_id: identity, source: :observation, domain: 'verbosity', content: 'long' }]
    result = described_class.build(identity: identity, synapses: candidates, preferences: preferences)
    expect(result).to contain_exactly(hash_including(source_id: 'explicit', content: 'brief', source: :explicit))
  end

  it 'makes a scoped correction replace the rejected directive even if that directive was once explicit' do
    correction = trace(id: 'correction', domain_tags: ['partner:alice', 'correction'],
                       content: { domain: 'tone', corrected_constraint: { format: 'prose' }, conversation_id: 'c1' })
    candidates = [synapse(id: 'old', directive: { format: 'table' }, origin: 'explicit')]
    result = described_class.build(identity: identity, conversation_id: 'c1', synapses: candidates,
                                   traces: [correction])
    expect(result).to contain_exactly(hash_including(source_id: 'correction', content: { format: 'prose' },
                                                     source: :correction))
    other = described_class.build(identity: identity, conversation_id: 'c2', synapses: candidates, traces: [correction])
    expect(other.map { |slot| slot[:source_id] }).to eq(['old'])
  end

  it 'does not turn generic negative feedback into an invented replacement preference' do
    correction = trace(id: 'negative', domain_tags: ['partner:alice', 'correction'],
                       content: { correction_type: 'explicit_negative_feedback', domain: 'tone' })
    expect(described_class.build(identity: identity, synapses: [], traces: [correction])).to eq([])
  end

  it 'unwraps authorized ranked memory without treating ranking as proof of usefulness' do
    memory = trace(id: 'decision', content: 'Use PostgreSQL')
    result = described_class.build(identity: identity, synapses: [], traces: [{ trace: memory, score: 0.9 }])
    expect(result).to contain_exactly(hash_including(type: :trace, source_id: 'decision', content: 'Use PostgreSQL',
                                                     source: :memory))
  end

  it 'caps slots while keeping the strongest eligible candidates' do
    candidates = 10.times.map do |index|
      synapse(id: "s#{index}", domain: "d#{index}", confidence: 0.65 + (index * 0.01))
    end
    result = described_class.build(identity: identity, synapses: candidates)
    expect(result.map { |slot| slot[:source_id] }).to eq(%w[s9 s8 s7 s6 s5 s4 s3])
    allow(Legion::Gaia).to receive(:settings).and_return(partner_model: { max_slots: 3 })
    expect(described_class.build(identity: identity, synapses: candidates).map do |slot|
      slot[:source_id]
    end).to eq(%w[s9 s8 s7])
  end

  it 'does not let a setting bypass the working-memory hard bound' do
    allow(Legion::Gaia).to receive(:settings).and_return(partner_model: { max_slots: 1000 })
    candidates = 20.times.map { |index| synapse(id: "s#{index}", domain: "d#{index}") }
    expect(described_class.build(identity: identity, synapses: candidates).size).to eq(7)
  end

  it 'discloses observe-only evidence without injecting it into working memory' do
    Legion::Gaia::BehavioralSynapse.crystallize(identity: identity, domain: 'tone', directive: 'casual',
                                                origin: 'emergent')
    result = described_class.build(identity: identity)
    expect(result).to be_empty
    expect(described_class.observe_mode_entries(identity: identity)).to include(hash_including(domain: 'tone',
                                                                                               autonomy_mode: :observe))
    expect(described_class.observe_mode_entries(identity: 'bob')).to be_empty
  end

  context 'with live scoped calibration' do
    let(:weights) { { 'tone_adjustment' => 0.41, 'verbosity_adjustment' => 0.9 } }
    let(:calibration) { double('live alice calibration') }

    before do
      constants = Module.new
      constants.const_set(:NEUTRAL_SCORE, 0.5)
      constants.const_set(:SUPPRESSION_THRESHOLD, 0.4)
      stub_const('Legion::Extensions::Agentic::Social::Calibration::Helpers::Constants', constants)
      allow(calibration).to receive(:calibration_weights).with(identity: identity) {
        { success: true, weights: weights.dup }
      }
      allow(Legion::Gaia).to receive(:calibration_runner_for).with(identity: identity,
                                                                   create: false).and_return(calibration)
    end

    it 'changes inferred selection with the same live calibrated weights, without changing another humans model' do
      candidates = [synapse(id: 'tone', confidence: 0.9),
                    synapse(id: 'brief', domain: 'custom-detail', confidence: 0.7,
                            advisory_type: 'verbosity_adjustment')]
      selected = described_class.build(identity: identity, synapses: candidates)
      expect(selected.map { |slot| slot[:source_id] }).to eq(%w[brief tone])
      expect(selected.map { |slot| slot[:advisory_type] }).to eq(%i[verbosity_adjustment tone_adjustment])
      weights['tone_adjustment'] = 0.2
      expect(described_class.build(identity: identity, synapses: candidates).map do |slot|
        slot[:source_id]
      end).to eq(['brief'])
      others = candidates.map { |candidate| candidate.merge(identity: 'bob') }
      expect(described_class.build(identity: 'bob', synapses: others).map do |slot|
        slot[:source_id]
      end).to eq(%w[tone brief])
    end

    it 'never lets calibration suppress an explicit preference, correction, or factual memory' do
      weights.merge!('tone_adjustment' => 0.0, 'format_adjustment' => 0.0, 'context_injection' => 0.0)
      preferences = [{ id: 'explicit', owner_id: identity, source: :explicit, domain: 'tone',
                       content: 'plain speaking' }]
      correction = trace(id: 'correction', domain_tags: ['partner:alice', 'correction'],
                         content: { domain: 'format', corrected_constraint: { format: 'prose' } })
      fact = trace(id: 'decision', domain: 'database', content: 'Use PostgreSQL')
      result = described_class.build(identity: identity, synapses: [synapse(id: 'inferred')],
                                     traces: [correction, fact], preferences: preferences)
      expect(result.map { |slot| slot[:source_id] }).to contain_exactly('explicit', 'correction', 'decision')
      expect(result.find { |slot| slot[:source_id] == 'correction' }[:advisory_type]).to eq(:format_adjustment)
      expect(result.find { |slot| slot[:source_id] == 'decision' }[:advisory_type]).to eq(:context_injection)
    end
  end
end
