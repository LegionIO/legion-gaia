# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Disclosure do
  before do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
    allow(Legion::Gaia).to receive(:registry).and_return(nil)
    allow(Legion::Gaia).to receive(:calibration_runner_for).and_return(nil)
  end

  after do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
  end

  it 'reads the same live bond and behavior used by partner decisions, never another human' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.8)
    Legion::Gaia::BondRegistry.register('bob', bond: :partner, strength: 0.4)
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'alice', domain: 'format', directive: 'prose',
                                                origin: 'explicit')
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'bob', domain: 'format', directive: 'private format',
                                                origin: 'explicit')
    report = described_class.report(identity: 'alice')
    expect(report[:bond_state]).to include(bond: :partner, strength: 0.8)
    expect(report[:behavioral_synapses]).to contain_exactly(hash_including(domain: 'format', directive: 'prose'))
    Legion::Gaia::BondRegistry.reinforce('alice')
    expect(described_class.report(identity: 'alice')[:bond_state][:strength]).to be > report[:bond_state][:strength]
  end

  it 'discloses a restored bond from the actual registry rather than an unused tracker instance' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.8)
    snapshots = Legion::Gaia::BondTracker.to_apollo_entries
    store = double('snapshot store')
    allow(store).to receive(:query_by_tags) do |tags:, limit:|
      matches = snapshots.select { |entry| (tags - entry[:tags]).empty? }
      { success: true, results: limit ? matches.first(limit) : matches }
    end
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BondTracker.from_apollo(store: store)
    expect(described_class.report(identity: 'alice')[:bond_state]).to include(bond: :partner, strength: 0.8)
  end

  it 'reads calibration weights from the registered live per-human runner' do
    weights = { brevity: 0.8 }
    runner = double('live calibration')
    allow(runner).to receive(:calibration_weights) { { success: true, weights: weights.dup } }
    allow(Legion::Gaia).to receive(:calibration_runner_for).with(identity: 'alice').and_return(runner)
    expect(described_class.report(identity: 'alice')[:calibration_weights]).to eq(brevity: 0.8)
    weights[:brevity] = 0.4
    expect(described_class.report(identity: 'alice')[:calibration_weights]).to eq(brevity: 0.4)
    expect(described_class.report(identity: 'bob')[:calibration_weights]).to be_nil
  end

  it 'does not mislabel a node-global imprint as personal knowledge' do
    bootstrap = double('global bootstrap', imprint_active?: true, observation_count: 500)
    stub_const('Legion::Extensions::Coldstart::Helpers::Bootstrap', double(instance: bootstrap))
    expect(described_class.report(identity: 'alice')[:imprint_state]).to be_nil
  end

  it 'reports prediction accuracy from the same live prediction runner and leaves unavailable state unknown' do
    registry = double('registry')
    prediction = double('live predictions', prediction_accuracy: { accuracy: 0.75, total_outcomes: 4 })
    allow(registry).to receive(:runner_instances_for).with(identity: 'alice')
                                                     .and_return(Prediction_Prediction: prediction)
    allow(registry).to receive(:runner_instances_for).with(identity: 'bob').and_return({})
    allow(Legion::Gaia).to receive(:registry).and_return(registry)
    expect(described_class.report(identity: 'alice')[:prediction_accuracy]).to eq(accuracy: 0.75, total_outcomes: 4)
    expect(described_class.report(identity: 'bob')[:prediction_accuracy]).to be_nil
  end

  it 'distinguishes local persistence from external processing and managed deletion scope' do
    stub_const('Legion::Apollo::Local', double(started?: false))
    report = described_class.report(identity: 'alice')
    expect(report[:data_locality]).to include(partner_store: :memory_only, external_processing: :deployment_dependent)
    expect(report[:deletion_scope]).to eq(:gaia_managed_state)
  end

  it 'requires a human identity instead of returning a global view' do
    expect(described_class.report(identity: nil)).to eq(available: false, reason: :missing_identity)
  end
end
