# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::BondRegistry do
  before { described_class.reset! }
  after { described_class.reset! }

  it 'preserves accumulated evidence and origin on repeated channel registration' do
    described_class.register('alice', bond: :partner, strength: 0.7, origin: :earned)
    described_class.reinforce('alice')
    before = described_class.entry(identity: 'alice')
    described_class.register('alice', bond: :partner, strength: 0.1, channel_identity: 'U123', last_channel: :slack)
    expect(described_class.entry(identity: 'alice')).to include(before.slice(:strength, :since, :origin,
                                                                             :reinforcement_count))
    expect(described_class.channel_identity('alice')).to eq('U123')
  end

  it 'returns detached state rather than allowing consumers to mutate live bonds' do
    described_class.register('alice', bond: :partner, strength: 0.8)
    value = described_class.entry(identity: 'alice')
    value[:identity].replace('bob')
    value[:strength] = 0.0
    expect(described_class.partner?('alice')).to be true
    expect(described_class.all_bonds.first[:identity]).to eq('alice')
  end

  it 'earns a provisional relationship through reinforcement with diminishing returns' do
    described_class.register('alice', bond: :partner, strength: 0.55)
    described_class.reinforce('alice')
    expect(described_class.partner?('alice')).to be false
    described_class.reinforce('alice')
    expect(described_class.entry(identity: 'alice')).to include(origin: :earned, reinforcement_count: 2)
    expect(described_class.partner?('alice')).to be true
    30.times { described_class.reinforce('alice', direct_address: true, new_channel: true, multiplier: 3.0) }
    expect(described_class.entry(identity: 'alice')[:strength]).to be_between(0.6, 1.0)
  end

  it 'decays strength without resetting relationship history' do
    described_class.register('alice', bond: :partner, strength: 0.8, origin: :earned)
    before = described_class.entry(identity: 'alice')
    described_class.apply_decay
    expect(described_class.entry(identity: 'alice')[:strength]).to be < before[:strength]
    expect(described_class.entry(identity: 'alice')).to include(before.slice(:since, :origin))
  end

  it 'never re-registers or recommends a blocked relationship' do
    described_class.register('alice', bond: :partner, strength: 0.8)
    described_class.set_bond_state('alice', :revoked)
    expect(described_class.register('alice', bond: :partner, strength: 1.0)).to be_nil
    expect(described_class.reinforce('alice')).to be_nil
    expect(described_class.partner?('alice')).to be false
    expect(described_class.partner_entry).to be_nil
  end

  it 'chooses the latest valid snapshot deterministically and preserves original timestamps' do
    old = { identity: 'alice', bond: :partner, origin: :earned, strength: 0.7, since: '2020-01-01T00:00:00Z' }
    current = old.merge(strength: 0.9, reinforcement_count: 20, last_reinforced: '2026-01-01T00:00:00Z')
    rows = [
      { id: 2, content: Legion::JSON.dump(current), updated_at: '2026-01-02' },
      { id: 1, content: Legion::JSON.dump(old), updated_at: '2026-01-01' },
      { id: 3, content: '{invalid', updated_at: '2026-01-03' },
      { id: 4, content: Legion::JSON.dump(current.merge(strength: 'invalid')), updated_at: '2026-01-04' },
      { id: 5, content: Legion::JSON.dump(current.merge(identity_key: 'another-owner')), updated_at: '2026-01-05' }
    ]
    store = double('local store')
    allow(store).to receive(:query_by_tags).with(tags: described_class::LIFECYCLE_TAGS, limit: nil)
                                           .and_return(success: true, results: [])
    allow(store).to receive(:query_by_tags).with(tags: described_class::TO_APOLLO_TAGS, limit: nil)
                                           .and_return(success: true, results: rows)
    expect(described_class.from_apollo(store: store)).to be true
    expect(described_class.entry(identity: 'alice')).to include(
      strength: 0.9, origin: :earned, reinforcement_count: 20,
      since: Time.utc(2020, 1, 1), last_reinforced: Time.utc(2026, 1, 1)
    )
    expect(described_class.dirty?).to be false
  end

  it 'fails closed when lifecycle barriers cannot be loaded' do
    store = double('unavailable store', query_by_tags: { success: false })
    expect(described_class.from_apollo(store: store)).to be false
    expect(described_class.register('new-person', bond: :partner)).to be_nil
    expect(described_class.blocked?(identity: 'anyone')).to be true
  end

  it 'blocks unknown lifecycle state with no store and recovers when the store becomes available' do
    expect(described_class.hydrate_lifecycle(store: nil)).to be false
    expect(described_class.lifecycle_ready?).to be false
    expect(described_class.register('alice', bond: :partner)).to be_nil
    store = double('available store', query_by_tags: { success: true, results: [] })
    expect(described_class.hydrate_lifecycle(store: store)).to be true
    expect(described_class.lifecycle_ready?).to be true
    expect(described_class.register('alice', bond: :partner)[:identity]).to eq('alice')
  end
end
