# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::BehavioralSynapse do
  before do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
  end

  after do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
  end

  it 'separates identities and domains even when their colon-joined keys would collide' do
    first = described_class.crystallize(identity: 'a:b', domain: 'c', directive: 'first')
    second = described_class.crystallize(identity: 'a', domain: 'b:c', directive: 'second')
    expect(first[:id]).not_to eq(second[:id])
    expect(described_class.all_for(identity: 'a').map { |entry| entry[:directive] }).to eq(['second'])
    described_class.erase_partner!(identity: 'a')
    expect(described_class.for(identity: 'a:b', domain: 'c')[:directive]).to eq('first')
  end

  it 'requires the same identity to grade a behavior even with a known behavior ID' do
    entry = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm', origin: 'explicit')
    result = described_class.record_outcome(id: entry[:id], identity: 'bob', outcome: :failure)
    expect(result).to eq(found: false)
    expect(described_class.for(identity: 'alice', domain: 'tone')[:confidence]).to eq(0.7)
  end

  it 'dampens repeatedly rejected behavior instead of strengthening the rejected directive' do
    entry = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm', origin: 'explicit')
    3.times { described_class.record_outcome(id: entry[:id], identity: 'alice', outcome: :failure) }
    result = described_class.for(identity: 'alice', domain: 'tone')
    expect(result).to include(status: 'dampened', confidence: 0.29, consecutive_successes: 0)
    expect(described_class::Math.autonomy_mode(result[:confidence])).to eq(:observe)
  end

  it 'does not allow snapshot consumers to rewrite live behavior' do
    entry = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm',
                                        evidence_trace_ids: ['trace'])
    entry[:directive].replace('hostile')
    entry[:evidence_trace_ids].first.replace('other')
    expect(described_class.for(identity: 'alice',
                               domain: 'tone')).to include(directive: 'warm',
                                                           evidence_trace_ids: ['trace'])
  end

  it 'preserves an established directive when crystallization is repeated' do
    first = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm')
    second = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'hostile')
    expect(second).to include(id: first[:id], directive: 'warm')
  end

  it 'decays confidence by elapsed time without confusing feedback counts' do
    past = Time.utc(2026, 1, 1)
    allow(Time).to receive(:now).and_return(past)
    described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm', origin: 'explicit')
    allow(Time).to receive(:now).and_return(past + 86_400)
    result = described_class.for(identity: 'alice', domain: 'tone')
    expect(result[:confidence]).to be < 0.7
    expect(result[:consecutive_successes]).to eq(0)
    expect(result[:last_reinforced_at]).to eq(past + 86_400)
  end

  it 'blocks reads and writes after consent revocation' do
    entry = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'warm')
    Legion::Gaia::BondRegistry.set_bond_state('alice', :revoked)
    expect(described_class.for(identity: 'alice', domain: 'tone')).to be_nil
    expect(described_class.all_for(identity: 'alice')).to be_empty
    expect(described_class.crystallize(identity: 'alice', domain: 'other', directive: 'new')).to be_nil
    expect(described_class.record_outcome(id: entry[:id], identity: 'alice', outcome: :success)).to eq(found: false)
  end

  it 'hydrates the latest valid domain snapshot and not another identity with the same domain' do
    time = Time.now.utc.iso8601
    base = { id: 'old', identity: 'alice', domain: 'tone', directive: 'old', confidence: 0.3,
             origin: 'emergent', status: 'active', last_reinforced_at: time, created_at: time }
    rows = [
      { id: 3, content: Legion::JSON.dump(base.merge(directive: 'current', confidence: 0.7)),
        updated_at: '2026-10-02' },
      { id: 1, content: Legion::JSON.dump(base), updated_at: '2026-10-01' },
      { id: 2, content: Legion::JSON.dump(base.merge(id: 'bob', identity: 'bob', directive: 'other')),
        updated_at: '2026-10-01' },
      { id: 4, content: Legion::JSON.dump(base.merge(confidence: 'invalid')), updated_at: '2026-10-03' },
      { id: 5, content: Legion::JSON.dump(base.merge(identity_key: 'another-owner')), updated_at: '2026-10-04' }
    ]
    store = double('local store', query_by_tags: { success: true, results: rows })
    expect(described_class.from_apollo(store: store)).to be true
    expect(described_class.for(identity: 'alice', domain: 'tone')).to include(directive: 'current', confidence: 0.7)
    expect(described_class.for(identity: 'bob', domain: 'tone')[:directive]).to eq('other')
  end
end
