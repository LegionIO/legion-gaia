# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'
require 'legion/apollo/local'
require 'legion/gaia/bond_tracker'

RSpec.describe Legion::Gaia::TrackerPersistence do
  let(:db) { Sequel.sqlite }
  let(:store) { Legion::Apollo::Local }
  let(:bonds) { Legion::Gaia::BondRegistry }
  let(:behavior) { Legion::Gaia::BehavioralSynapse }

  before do
    local_db = db
    stub_const('Legion::Data::Local', Module.new do
      define_singleton_method(:connected?) { true }
      define_singleton_method(:connection) { local_db }
      define_singleton_method(:register_migrations) { |**_| nil }
    end)
    Sequel::Migrator.run(db, store::MIGRATION_PATH)
    store.start
    described_class.reset!
    bonds.reset!
    behavior.reset!
    described_class.register_tracker(:bond, tracker: Legion::Gaia::BondTracker, tags: bonds::TO_APOLLO_TAGS)
    described_class.register_tracker(:behavior, tracker: behavior::Tracker.new, tags: behavior::TO_APOLLO_TAGS)
  end

  after do
    store.reset!
    described_class.reset!
    bonds.reset!
    behavior.reset!
    db.disconnect
  end

  it 'persists every live identity and behavior domain without tag-key collisions' do
    %w[Alice alice a:b].each do |identity|
      bonds.register(identity, bond: :partner, strength: 0.7, origin: :earned)
      %w[tone brevity].each do |domain|
        behavior.crystallize(identity: identity, domain: domain, directive: "#{identity} #{domain}", origin: 'explicit')
      end
    end
    expect(described_class.flush_all(store: store)).to be true
    bonds.reinforce('Alice')
    behavior.record_outcome(id: behavior.for(identity: 'Alice', domain: 'tone')[:id], identity: 'Alice',
                            outcome: :failure)
    expect(described_class.flush_dirty(store: store)).to be true
    current = bonds.entry(identity: 'Alice')
    bonds.reset!
    behavior.reset!
    expect(described_class.hydrate_all(store: store)).to be true
    expect(bonds.entry(identity: 'Alice')).to include(current.slice(:strength, :origin, :reinforcement_count))
    expect(bonds.entry(identity: 'Alice')[:since]).to be_within(1).of(current[:since])
    expect(bonds.entry(identity: 'alice')[:reinforcement_count]).to eq(0)
    expect(behavior.for(identity: 'Alice', domain: 'tone')[:confidence]).to be_within(0.001).of(0.65)
    expect(behavior.for(identity: 'alice', domain: 'tone')[:confidence]).to be_within(0.001).of(0.7)
    expect(behavior.all_for(identity: 'a:b').map do |entry|
      entry[:directive]
    end).to contain_exactly('a:b tone', 'a:b brevity')
  end

  it 'retains dirty state after a failed write and still flushes later trackers' do
    bonds.register('alice', bond: :partner, strength: 0.8)
    behavior.crystallize(identity: 'alice', domain: 'tone', directive: 'warm')
    allow(store).to receive(:upsert).and_wrap_original do |method, **kwargs|
      kwargs[:tags].include?('bond') ? { success: false } : method.call(**kwargs)
    end
    expect(described_class.flush_all(store: store)).to be false
    expect(bonds.dirty?).to be true
    expect(behavior.dirty?).to be false
    behavior.reset!
    behavior.from_apollo(store: store)
    expect(behavior.for(identity: 'alice', domain: 'tone')[:directive]).to eq('warm')
    expect(described_class.last_flush_at).to be_nil
    allow(store).to receive(:upsert).and_call_original
    expect(described_class.flush_dirty(store: store)).to be true
    expect(bonds.dirty?).to be false
  end

  it 'preserves an update made while an older snapshot is being acknowledged' do
    bonds.register('alice', bond: :partner, strength: 0.7)
    changed = false
    allow(store).to receive(:upsert).and_wrap_original do |method, **kwargs|
      result = method.call(**kwargs)
      unless changed
        changed = true
        bonds.reinforce('alice')
      end
      result
    end
    expect(described_class.flush_tracker(tracker: Legion::Gaia::BondTracker, store: store)).to be true
    expect(bonds.dirty?).to be true
    expect(described_class.flush_tracker(tracker: Legion::Gaia::BondTracker, store: store)).to be true
    bonds.reset!
    bonds.from_apollo(store: store)
    expect(bonds.entry(identity: 'alice')[:reinforcement_count]).to eq(1)
  end

  it 'does not treat an unknown write response as durable success' do
    bonds.register('alice', bond: :partner)
    allow(store).to receive(:upsert).and_return({})
    expect(described_class.flush_tracker(tracker: Legion::Gaia::BondTracker, store: store)).to be false
    expect(bonds.dirty?).to be true
  end

  it 'never falls back to shared storage when local persistence is unavailable' do
    bonds.register('alice', bond: :partner)
    expect(described_class.flush_all(store: nil)).to be false
    expect(bonds.dirty?).to be true
    expect(db[:local_knowledge].count).to eq(0)
  end

  it 'fails closed without storage and immediately retries once local storage appears' do
    expect(described_class.hydrate_all(store: nil)).to be false
    expect(bonds.blocked?(identity: 'alice')).to be true
    expect(described_class.hydration_due?).to be true
    expect(described_class.hydrate_all(store: store)).to be true
    expect(bonds.blocked?(identity: 'alice')).to be false
    expect(described_class.hydration_due?).to be false
  end

  it 'bounds retries after a real storage read failure' do
    now = Time.utc(2026, 1, 1)
    allow(Time).to receive(:now).and_return(now)
    unavailable = double('unavailable local store', query_by_tags: { success: false })
    expect(described_class.hydrate_all(store: unavailable)).to be false
    expect(bonds.lifecycle_ready?).to be false
    expect(described_class.hydration_due?).to be false
    allow(Time).to receive(:now).and_return(now + described_class::FLUSH_INTERVAL)
    expect(described_class.hydration_due?).to be true
  end
end
