# frozen_string_literal: true

require 'spec_helper'
require 'sequel'
require 'sequel/extensions/migration'
require 'legion/apollo/local'
require 'legion/gaia/calibration_tracker'
require 'legion/extensions/agentic/social/calibration/helpers/constants'
require 'legion/extensions/agentic/social/calibration/helpers/calibration_store'

RSpec.describe Legion::Gaia::CalibrationTracker do
  let(:db) { Sequel.sqlite }
  let(:store) { Legion::Apollo::Local }
  let(:provider_class) { Legion::Extensions::Agentic::Social::Calibration::Helpers::CalibrationStore }
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
    Legion::Gaia::BondRegistry.reset!
    persistence.reset!
  end

  after do
    store.reset!
    Legion::Gaia::BondRegistry.reset!
    persistence.reset!
    db.disconnect
  end

  def apply_feedback(tracker:, identity:, advisory_id:, content:)
    tracker.record_advisory(advisory_id: advisory_id, advisory_types: [:tone_adjustment],
                            applied: { identity: identity, exchange_id: advisory_id })
    tracker.evaluate_reaction(observation: { identity: identity, exchange_id: advisory_id, advisory_id: advisory_id,
                                             content: content, content_length: content.length })
  end

  def persist_adapter(identity:, tracker:)
    adapter = described_class.new(identity: identity, tracker: tracker)
    expect(persistence.flush_tracker(tracker: adapter, store: store)).to be true
    adapter
  end

  it 'restores the same live per-human weights and history without case-insensitive owner collisions' do
    alice = provider_class.new
    other = provider_class.new
    apply_feedback(tracker: alice, identity: 'Alice', advisory_id: 'a1', content: 'stop')
    apply_feedback(tracker: other, identity: 'alice', advisory_id: 'b1', content: 'thanks')
    persist_adapter(identity: 'Alice', tracker: alice)
    persist_adapter(identity: 'alice', tracker: other)

    restored_alice = provider_class.new
    restored_other = provider_class.new
    expect(described_class.new(identity: 'Alice', tracker: restored_alice).from_apollo(store: store)).to be true
    expect(described_class.new(identity: 'alice', tracker: restored_other).from_apollo(store: store)).to be true
    expect(restored_alice.calibration_weights).to eq(alice.calibration_weights)
    expect(restored_other.calibration_weights).to eq(other.calibration_weights)
    expect(restored_alice.calibration_weights).not_to eq(restored_other.calibration_weights)
    expect(restored_alice.history).to eq(alice.history)
    expect(restored_other.history).to eq(other.history)
  end

  it 'does not infer an owner for legacy global calibration entries' do
    legacy = provider_class.new
    apply_feedback(tracker: legacy, identity: 'old-owner', advisory_id: 'old', content: 'stop')
    legacy.to_apollo_entries.each { |entry| store.upsert(**entry) }
    fresh = provider_class.new
    neutral = fresh.calibration_weights
    expect(described_class.new(identity: 'new-owner', tracker: fresh).from_apollo(store: store)).to be true
    expect(fresh.calibration_weights).to eq(neutral)
    expect(fresh.history).to be_empty
  end

  it 'selects newest valid scoped weights and history rather than a malformed newer snapshot' do
    source = provider_class.new
    adapter = described_class.new(identity: 'alice', tracker: source)
    apply_feedback(tracker: source, identity: 'alice', advisory_id: 'first', content: 'stop')
    adapter.to_apollo_entries.each { |entry| store.upsert(**entry, tags: entry[:tags] + ['historical']) }
    apply_feedback(tracker: source, identity: 'alice', advisory_id: 'second', content: 'thanks')
    expect(persistence.flush_tracker(tracker: adapter, store: store)).to be true
    corrupted = adapter.to_apollo_entries.first
    store.upsert(**corrupted, content: '{invalid', tags: corrupted[:tags] + ['corrupt'])

    restored = provider_class.new
    expect(described_class.new(identity: 'alice', tracker: restored).from_apollo(store: store)).to be true
    expect(restored.calibration_weights).to eq(source.calibration_weights)
    expect(restored.history).to eq(source.history)
  end

  it 'persists baseline updates even when the provider does not mark them dirty' do
    source = provider_class.new
    adapter = persist_adapter(identity: 'alice', tracker: source)
    source.mark_clean!
    source.update_baseline(latency: 42, length: 100)
    persistence.register_tracker(:alice_calibration, tracker: adapter, tags: described_class::TAGS)
    expect(persistence.flush_dirty(store: store)).to be true

    restored = provider_class.new
    expect(described_class.new(identity: 'alice', tracker: restored).from_apollo(store: store)).to be true
    snapshot = Legion::JSON.load(restored.to_apollo_entries.first[:content])
    expect(snapshot[:baselines]).to eq(avg_latency: 42.0, avg_length: 100.0)
  end

  it 'keeps failed calibration snapshots retryable' do
    source = provider_class.new
    adapter = described_class.new(identity: 'alice', tracker: source)
    apply_feedback(tracker: source, identity: 'alice', advisory_id: 'first', content: 'stop')
    allow(store).to receive(:upsert).and_return(success: false)
    expect(persistence.flush_tracker(tracker: adapter, store: store)).to be false
    expect(adapter.dirty?).to be true
    allow(store).to receive(:upsert).and_call_original
    expect(persistence.flush_tracker(tracker: adapter, store: store)).to be true
    restored = provider_class.new
    expect(described_class.new(identity: 'alice', tracker: restored).from_apollo(store: store)).to be true
    expect(restored.calibration_weights).to eq(source.calibration_weights)
  end

  it 'rejects failed reads and mismatched persisted owner claims without mutating the live provider' do
    source = provider_class.new
    original = source.calibration_weights
    adapter = described_class.new(identity: 'alice', tracker: source)
    failed = double('failed store', query_by_tags: { success: false })
    expect(adapter.from_apollo(store: failed)).to be false
    expect(adapter.from_apollo(store: nil)).to be false
    entry = adapter.to_apollo_entries.first
    content = Legion::JSON.load(entry[:content]).merge(identity: 'bob', weights: { tone_adjustment: 0.1 })
    store.upsert(**entry, content: Legion::JSON.dump(content))
    expect(adapter.from_apollo(store: store)).to be false
    expect(source.calibration_weights).to eq(original)
  end
end
