# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Gut do
  let(:identity) { 'alice' }
  let(:registry) { double('registry') }
  let(:memory) { double('scoped memory') }

  before do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
    allow(Legion::Gaia).to receive(:registry).and_return(registry)
    allow(registry).to receive(:runner_instances_for).with(identity: identity).and_return(Memory_Traces: memory)
    allow(registry).to receive(:runner_instances_for).with(identity: 'bob').and_return({})
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [])
  end

  after do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
  end

  def correction(identity: 'alice', conversation_id: 'c1', constraint: { format: 'prose' })
    { trace_id: "#{identity}-correction", trace_type: :episodic, strength: 0.9,
      domain_tags: ['correction', "partner:#{identity}"],
      content_payload: { domain: 'format', conversation_id: conversation_id, corrected_constraint: constraint } }
  end

  it 'enforces a real stored structured directive only for its owner' do
    Legion::Gaia::BehavioralSynapse.crystallize(identity: identity, domain: 'verbosity', origin: 'explicit',
                                                directive: { budget_ratio: 0.5 }, evidence_trace_ids: ['budget'])
    draft = { length_tokens: 300, baseline_tokens: 400 }
    expect(described_class.check(identity: identity,
                                 draft_stats: draft)).to include(conflict: true,
                                                                 violated_trace_ids: ['budget'])
    expect(described_class.check(identity: 'bob', draft_stats: draft)).to eq(conflict: false)
    expect(described_class.check(identity: identity,
                                 draft_stats: draft.merge(length_tokens: 100))).to eq(conflict: false)
  end

  it 'recognizes supported episodic correction tags and the corrected constraint' do
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [correction])
    result = described_class.check(identity: identity, draft_stats: { format: 'table', conversation_id: 'c1' })
    expect(result).to include(conflict: true, violated_trace_ids: ['alice-correction'], directive: { format: 'prose' })
  end

  it 'ignores returned traces from another human or conversation even if retrieval was not properly filtered' do
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [correction(identity: 'bob'),
                                                                      correction(conversation_id: 'c2')])
    expect(described_class.check(identity: identity,
                                 draft_stats: { format: 'table',
                                                conversation_id: 'c1' })).to eq(conflict: false)
  end

  it 'lets the explicit correction replace the old conflicting synapse rather than vetoing the corrected format' do
    Legion::Gaia::BehavioralSynapse.crystallize(identity: identity, domain: 'format', origin: 'explicit',
                                                directive: { format: 'table' })
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [correction])
    expect(described_class.check(identity: identity,
                                 draft_stats: { format: 'prose',
                                                conversation_id: 'c1' })).to eq(conflict: false)
    expect(described_class.check(identity: identity,
                                 draft_stats: { format: 'table',
                                                conversation_id: 'c1' })[:conflict]).to be true
  end

  it 'enforces explicit token limits without relying on a fabricated correction trace type' do
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [correction(constraint: { budget_tokens: 100 })])
    expect(described_class.check(identity: identity,
                                 draft_stats: { length_tokens: 101,
                                                conversation_id: 'c1' })[:conflict]).to be true
    expect(described_class.check(identity: identity,
                                 draft_stats: { length_tokens: 100,
                                                conversation_id: 'c1' })).to eq(conflict: false)
  end

  it 'vetoes reapplying an explicitly rejected source without inventing a preference' do
    trace = correction(constraint: nil)
    trace[:content_payload].merge!(correction_type: :explicit_negative_feedback, applied_synapse_ids: ['rejected'])
    allow(memory).to receive(:retrieve_by_domain).and_return(traces: [trace])
    result = described_class.check(identity: identity,
                                   draft_stats: { conversation_id: 'c1',
                                                  applied_signals: { behavioral_synapse_ids: ['rejected'] } })
    expect(result).to include(conflict: true)
    expect(result[:directive]).not_to have_key(:format)
    expect(result[:directive]).not_to have_key(:budget_tokens)
  end

  it 'returns unavailable when its deterministic work budget expires' do
    allow(described_class).to receive(:monotonic_now).and_return(0.0, 1.0)
    expect(described_class.check(identity: identity, draft_stats: {})).to be_nil
  end

  it 'does not build an anonymous correction view' do
    expect(described_class.check(identity: nil, draft_stats: {})).to be_nil
  end
end
