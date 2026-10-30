# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'
require 'legion/apollo/local'
require 'legion/gaia/bond_tracker'

RSpec.describe Legion::Gaia::DeathProtocol do
  let(:db) { Sequel.sqlite }
  let(:store) { Legion::Apollo::Local }
  let(:bonds) { Legion::Gaia::BondRegistry }
  let(:behavior) { Legion::Gaia::BehavioralSynapse }
  let(:persistence) { Legion::Gaia::TrackerPersistence }

  before do
    local_db = db
    stub_const('Legion::Data::Local', Module.new do
      define_singleton_method(:connected?) { true }
      define_singleton_method(:connection) { local_db }
      define_singleton_method(:register_migrations) { |**_| nil }
    end)
    Sequel::Migrator.run(db, store::MIGRATION_PATH)
    store.start
    bonds.reset!
    behavior.reset!
    persistence.reset!
    allow(Legion::Gaia).to receive(:apollo_local_store).and_return(store)
    Legion::Gaia.boot
    if defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)
      hide_const('Legion::Extensions::Mesh::Helpers::PreferenceProfile')
    end
    Legion::Gaia::AuditObserver.instance.reset!
    %w[a a:b].each do |identity|
      bonds.register(identity, bond: :partner, strength: 0.8)
      behavior.crystallize(identity: identity, domain: 'tone', directive: "private #{identity}", origin: 'explicit')
    end
    persistence.flush_all(store: store)
  end

  after do
    Legion::Gaia.shutdown if Legion::Gaia.started?
    store.reset!
    bonds.reset!
    behavior.reset!
    persistence.reset!
    db.disconnect
  end

  it 'requires explicit confirmation before changing a relationship' do
    expect { described_class.terminate_bond(identity: 'a', confirm: false, store: store) }.to raise_error(ArgumentError)
    expect(bonds.partner?('a')).to be true
  end

  it 'does not erase anything when the privacy barrier write fails' do
    allow(store).to receive(:upsert).and_return(success: false)
    result = described_class.terminate_bond(identity: 'a', confirm: true, store: store)
    expect(result).to include(terminated: false, durable: false, reason: :barrier_not_persisted)
    expect(bonds.terminating?('a')).to be true
    expect(bonds.entry(identity: 'a')).not_to be_nil
    expect(persistence.entries_for(store: store, tags: behavior::TO_APOLLO_TAGS).map do |row|
      Legion::JSON.load(row[:content])[:identity]
    end)
      .to contain_exactly('a', 'a:b')
  end

  it 'physically erases the exact identity while preserving another identity and its state after restart' do
    result = described_class.terminate_bond(identity: 'a', confirm: true, store: store)
    expect(result).to include(terminated: true, durable: true)
    expect(result[:receipt][:local_snapshots]).to include(erased: true, durable: true)
    bonds.reset!
    behavior.reset!
    expect(persistence.hydrate_all(store: store)).to be true
    expect(bonds.terminated?('a')).to be true
    expect(bonds.entry(identity: 'a')).to be_nil
    expect(behavior.all_for(identity: 'a')).to be_empty
    expect(bonds.partner?('a:b')).to be true
    expect(behavior.for(identity: 'a:b', domain: 'tone')[:directive]).to eq('private a:b')
    expect(bonds.register('a', bond: :partner, strength: 1.0)).to be_nil
  end

  it 'retains a durable barrier across process loss between journal commit and erasure' do
    expect(bonds.persist_lifecycle(identity: 'a', state: :terminating, store: store)).to be true
    bonds.reset!
    behavior.reset!
    expect(persistence.hydrate_all(store: store)).to be true
    expect(bonds.terminating?('a')).to be true
    expect(bonds.entry(identity: 'a')).to be_nil
    expect(behavior.all_for(identity: 'a')).to be_empty
    result = described_class.resume_pending(store: store)
    expect(result['a']).to include(terminated: true, durable: true)
    expect(persistence.entries_for(store: store, tags: behavior::TO_APOLLO_TAGS).map do |row|
      Legion::JSON.load(row[:content])[:identity]
    end)
      .to eq(['a:b'])
  end

  it 'reports partial erasure honestly and completes it on retry' do
    allow(Legion::Gaia).to receive(:erase_attribution!).and_return(erased: false, durable: false)
    result = described_class.terminate_bond(identity: 'a', confirm: true, store: store)
    expect(result).to include(terminated: false, durable: false)
    expect(bonds.terminating?('a')).to be true
    bonds.reset!
    behavior.reset!
    persistence.hydrate_all(store: store)
    expect(bonds.terminating?('a')).to be true
    allow(Legion::Gaia).to receive(:erase_attribution!).and_call_original
    expect(described_class.resume_pending(store: store)['a'][:terminated]).to be true
  end

  it 'loads consent revocations even if a historical storage TTL has expired' do
    expect(bonds.persist_lifecycle(identity: 'a', state: :revoked, store: store)).to be true
    db[:local_knowledge].update(expires_at: '2000-01-01T00:00:00.000Z')
    bonds.reset!
    behavior.reset!
    expect(persistence.hydrate_all(store: store)).to be true
    expect(bonds.blocked?(identity: 'a')).to be true
    expect(bonds.bond_state('a')).to eq(:revoked)
    expect(behavior.all_for(identity: 'a')).to be_empty
    expect(bonds.entry(identity: 'a:b')).not_to be_nil
  end
end
