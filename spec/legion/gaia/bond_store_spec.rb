# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/bond_store'

RSpec.describe Legion::Gaia::BondStore do
  let(:identity) { 'test_user_001' }
  let(:store) { described_class.new(identity: identity, bond_role: :partner) }

  describe '#initialize' do
    it 'sets identity as string' do
      expect(store.identity).to eq('test_user_001')
    end

    it 'sets bond_role' do
      expect(store.bond_role).to eq(:partner)
    end

    it 'starts with raw_score of 0.0' do
      expect(store.raw_score).to eq(0.0)
    end

    it 'has empty evidence_log' do
      expect(store.evidence_log).to be_empty
    end

    it 'is not dirty on creation' do
      expect(store).not_to be_dirty
    end
  end

  describe '#accumulate' do
    let(:observation) do
      {
        identity: identity,
        content_length: 150,
        direct_address: false,
        latency: 10.0,
        timestamp: Time.now.utc,
        channel: :teams
      }
    end

    it 'increases raw_score' do
      store.accumulate(observation)
      # base_delta = content_depth(0.003) * 0.15 + latency(0.003) * 0.10 = 0.00045 + 0.0003 = 0.00075
      # diminishing_factor = 1.0 (first call)
      # delta = 0.00075 * 1.0 * 1.0 = 0.00075
      expect(store.raw_score).to be > 0.0
    end

    it 'marks dirty' do
      store.accumulate(observation)
      expect(store).to be_dirty
    end

    it 'appends to evidence_log' do
      store.accumulate(observation)
      expect(store.evidence_log.size).to eq(1)
      expect(store.evidence_log.first[:delta]).to be > 0
    end

    it 'respects direct_address signal' do
      with_addr = observation.merge(direct_address: true)
      without_addr = observation.merge(direct_address: false)

      store_a = described_class.new(identity: 'a', bond_role: :partner)
      store_b = described_class.new(identity: 'b', bond_role: :partner)

      store_a.accumulate(with_addr)
      store_b.accumulate(without_addr)

      expect(store_a.raw_score).to be > store_b.raw_score
    end

    it 'respects imprint_multiplier' do
      store.accumulate(observation, imprint_multiplier: 3.0)
      expect(store.raw_score).to be > 0
    end

    it 'caps raw_score at 1.0' do
      10_000.times do
        store.accumulate(observation.merge(direct_address: true, content_length: 600))
      end
      expect(store.raw_score).to be <= 1.0
    end

    it 'captures identity columns from observation' do
      obs_with_id = observation.merge(
        identity_principal_id: 'principal-123',
        identity_canonical_name: 'matt',
        identity_id: 'id-456'
      )
      store.accumulate(obs_with_id)
      expect(store.identity_principal_id).to eq('principal-123')
      expect(store.identity_canonical_name).to eq('matt')
      expect(store.identity_id).to eq('id-456')
    end
  end

  describe '#strength' do
    it 'returns 0 when no evidence accumulated' do
      expect(store.strength).to be < 0.001
    end

    it 'returns a positive value after accumulation' do
      observation = {
        content_length: 200,
        direct_address: false,
        latency: 5.0,
        timestamp: Time.now.utc
      }
      store.accumulate(observation)
      expect(store.strength).to be > 0.0008
    end

    it 'clips provisional bonds at 0.5 ceiling' do
      prov_store = described_class.new(identity: 'prov', bond_role: :provisional)
      observation = {
        content_length: 300,
        direct_address: true,
        latency: 2.0,
        timestamp: Time.now.utc
      }

      100.times { prov_store.accumulate(observation) }
      expect(prov_store.strength).to be <= described_class::PROVISIONAL_CEILING
    end
  end

  describe 'provisional bonds' do
    it 'marks provisional? as true' do
      prov = described_class.new(identity: 'prov', bond_role: :provisional)
      expect(prov).to be_provisional
    end

    it 'marks non-provisional as false' do
      expect(store).not_to be_provisional
    end

    it 'confirms the bond and removes expiry' do
      prov = described_class.new(identity: 'prov', bond_role: :provisional)
      expect(prov).to be_provisional

      prov.confirm!
      expect(prov).not_to be_provisional
      expect(prov.bond_role).to eq(:partner)
    end
  end

  describe '#bell?' do
    it 'fires when crossing threshold boundaries' do
      observation = {
        content_length: 600,
        direct_address: true,
        latency: 1.0,
        timestamp: Time.now.utc
      }
      bells = []

      1000.times do
        store.accumulate(observation)
        strength = store.strength
        new_bells = store.bell?(strength)
        bells.concat(new_bells)
        break if store.raw_score >= 1.0
      end

      expect(bells).to include(0.25)
      # No duplicates
      expect(bells.uniq.sort).to eq(bells.sort)
    end

    it 'does not refire when already crossed' do
      observation = {
        content_length: 600,
        direct_address: true,
        latency: 1.0,
        timestamp: Time.now.utc
      }
      200.times { store.accumulate(observation) }
      strength = store.strength
      store.bell?(strength)

      # Strength goes up — already crossed threshold should not refire
      new_bells = store.bell?(strength + 0.05)
      expect(new_bells.size).to be < described_class::DEFAULT_BELL_THRESHOLDS.size
    end
  end

  describe '#mark_clean!' do
    it 'sets dirty to false' do
      observation = {
        content_length: 200,
        direct_address: false,
        timestamp: Time.now.utc
      }
      store.accumulate(observation)
      expect(store).to be_dirty

      store.mark_clean!
      expect(store).not_to be_dirty
    end
  end

  describe '#to_apollo_entries' do
    it 'returns entries with correct tags' do
      observation = {
        content_length: 200,
        direct_address: false,
        timestamp: Time.now.utc
      }
      store.accumulate(observation)

      entries = store.to_apollo_entries
      expect(entries.size).to be > 0
      summary = entries.find { |e| e[:tags].include?('bond_evidence') }
      expect(summary).not_to be_nil
      expect(summary[:tags]).to include('bond', 'gaia')
    end

    it 'includes identity columns when captured' do
      observation = {
        content_length: 200,
        direct_address: false,
        timestamp: Time.now.utc,
        identity_principal_id: 'p-1',
        identity_canonical_name: 'matt',
        identity_id: 'i-1'
      }
      store.accumulate(observation)
      entries = store.to_apollo_entries
      summary = entries.first
      expect(summary[:identity_canonical_name]).to eq('matt')
      expect(summary[:identity_principal_id]).to eq('p-1')
    end
  end

  describe '#from_apollo' do
    it 'reconstructs raw_score from Apollo query results' do
      fake_store = double('store')
      allow(fake_store).to receive(:query).and_return(
        success: true,
        results: [
          { confidence: 0.45, identity: identity }
        ]
      )
      store.from_apollo(store: fake_store)
      expect(store.raw_score).to eq(0.45)
    end

    it 'handles missing store gracefully' do
      expect { store.from_apollo(store: nil) }.not_to raise_error
    end
  end

  describe 'evidence_log ring buffer' do
    it 'caps at MAX_EVIDENCE entries' do
      observation = {
        content_length: 100,
        direct_address: false,
        timestamp: Time.now.utc
      }

      300.times { store.accumulate(observation) }
      expect(store.evidence_log.size).to be <= described_class::MAX_EVIDENCE
    end
  end
end