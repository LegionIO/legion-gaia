# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/bond_tracker'

RSpec.describe Legion::Gaia::BondTracker do
  before { Legion::Gaia::BondRegistry.reset! }
  after { Legion::Gaia::BondRegistry.reset! }

  it 'serializes the live relationship rather than a disconnected evidence accumulator' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.7, origin: :earned)
    Legion::Gaia::BondRegistry.reinforce('alice')
    state = Legion::JSON.load(described_class.to_apollo_entries.fetch(0).fetch(:content))
    expect(state).to include(identity: 'alice', origin: 'earned', reinforcement_count: 1)
    expect(state[:strength]).to eq(Legion::Gaia::BondRegistry.entry(identity: 'alice')[:strength])
    expect(described_class.dirty?).to be true
  end

  it 'does not clear live changes while serializing or acknowledging an older revision' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.7)
    revision = described_class.dirty_revision
    described_class.to_apollo_entries
    Legion::Gaia::BondRegistry.reinforce('alice')
    described_class.mark_clean!(revision: revision)
    expect(described_class.dirty?).to be true
    described_class.mark_clean!(revision: described_class.dirty_revision)
    expect(described_class.dirty?).to be false
  end
end
