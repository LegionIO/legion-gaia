# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::BehavioralSynapse do
  before { described_class.reset! }
  after  { described_class.reset! }

  # ---- Math module constants ----

  describe 'Math constants' do
    subject(:math) { described_class::Math }

    it 'has correct STARTING_SCORES' do
      expect(math::STARTING_SCORES).to eq(explicit: 0.7, emergent: 0.3, seeded: 0.5)
    end

    it 'has correct DECAY_RATE' do
      expect(math::DECAY_RATE).to eq(0.998)
    end

    it 'has correct CONSECUTIVE_BONUS_THRESHOLD' do
      expect(math::CONSECUTIVE_BONUS_THRESHOLD).to eq(50)
    end

    it 'has correct E_WEIGHT' do
      expect(math::E_WEIGHT).to eq(3.0)
    end

    it 'covers full 0..1 range in AUTONOMY_RANGES' do
      ranges = math::AUTONOMY_RANGES.values
      expect(ranges.map(&:min).min).to eq(0.0)
      expect(ranges.map(&:max).max).to eq(1.0)
    end
  end

  # ---- starting_score ----

  describe '.starting_score' do
    it 'returns 0.7 for explicit' do
      expect(described_class.starting_score(:explicit)).to eq(0.7)
    end

    it 'returns 0.3 for emergent' do
      expect(described_class.starting_score(:emergent)).to eq(0.3)
    end

    it 'returns 0.5 for seeded' do
      expect(described_class.starting_score(:seeded)).to eq(0.5)
    end

    it 'returns 0.3 for unknown origin' do
      expect(described_class.starting_score(:unknown_origin)).to eq(0.3)
    end
  end

  # ---- .for ----

  describe '.for' do
    it 'returns nil when no entry exists' do
      expect(described_class.for(identity: 'alice', domain: 'feedback')).to be_nil
    end

    it 'returns the entry after crystallize' do
      described_class.crystallize(identity: 'alice', domain: 'feedback', directive: 'be concise')
      entry = described_class.for(identity: 'alice', domain: 'feedback')
      expect(entry).to be_a(Hash)
      expect(entry[:identity]).to eq('alice')
    end
  end

  # ---- .crystallize ----

  describe '.crystallize' do
    it 'creates an entry at emergent starting confidence (0.3)' do
      entry = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'friendly')
      expect(entry[:confidence]).to eq(0.3)
      expect(entry[:origin]).to eq('emergent')
      expect(entry[:status]).to eq('active')
    end

    it 'is idempotent — returns same entry on second call' do
      first  = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'friendly')
      second = described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'other')
      expect(second[:id]).to eq(first[:id])
      expect(second[:directive]).to eq('friendly')
    end

    it 'creates an explicit entry at 0.7 when origin is explicit' do
      entry = described_class.crystallize(identity: 'bob', domain: 'length', directive: 'brief',
                                          origin: 'explicit')
      expect(entry[:confidence]).to be_within(0.001).of(0.7)
      expect(entry[:origin]).to eq('explicit')
    end

    it 'stores evidence_trace_ids' do
      entry = described_class.crystallize(identity: 'alice', domain: 'style', directive: 'bullets',
                                          evidence_trace_ids: %w[trace-1 trace-2])
      expect(entry[:evidence_trace_ids]).to eq(%w[trace-1 trace-2])
    end

    it 'assigns a UUID id' do
      entry = described_class.crystallize(identity: 'alice', domain: 'style2', directive: 'bullets')
      expect(entry[:id]).to match(/\A[0-9a-f-]{36}\z/)
    end
  end

  # ---- .record_outcome ----

  describe '.record_outcome' do
    let!(:entry) { described_class.crystallize(identity: 'alice', domain: 'voice', directive: 'warm') }

    it 'returns found: false for unknown id' do
      result = described_class.record_outcome(id: 'no-such-id', outcome: :success)
      expect(result[:found]).to eq(false)
    end

    it 'increases confidence on :success' do
      before_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      described_class.record_outcome(id: entry[:id], outcome: :success)
      after_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      expect(after_conf).to be > before_conf
    end

    it 'decreases confidence on :failure' do
      before_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      described_class.record_outcome(id: entry[:id], outcome: :failure)
      after_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      expect(after_conf).to be < before_conf
    end

    it 'success delta matches Math::ADJUSTMENTS[:success]' do
      before_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      described_class.record_outcome(id: entry[:id], outcome: :success)
      after_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      expect(after_conf - before_conf).to be_within(0.001).of(described_class::Math::ADJUSTMENTS[:success])
    end

    it 'failure delta matches Math::ADJUSTMENTS[:failure]' do
      before_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      described_class.record_outcome(id: entry[:id], outcome: :failure)
      after_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      expect(after_conf - before_conf).to be_within(0.001).of(described_class::Math::ADJUSTMENTS[:failure])
    end

    it 'scales delta by multiplier' do
      before_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      described_class.record_outcome(id: entry[:id], outcome: :success, multiplier: 2.0)
      after_conf = described_class.for(identity: 'alice', domain: 'voice')[:confidence]
      expected_delta = described_class::Math::ADJUSTMENTS[:success] * 2.0
      expect(after_conf - before_conf).to be_within(0.001).of(expected_delta)
    end

    it 'tracks consecutive successes' do
      3.times { described_class.record_outcome(id: entry[:id], outcome: :success) }
      refreshed = described_class.for(identity: 'alice', domain: 'voice')
      expect(refreshed[:consecutive_successes]).to eq(3)
      expect(refreshed[:consecutive_failures]).to eq(0)
    end

    it 'resets consecutive successes on failure' do
      2.times { described_class.record_outcome(id: entry[:id], outcome: :success) }
      described_class.record_outcome(id: entry[:id], outcome: :failure)
      refreshed = described_class.for(identity: 'alice', domain: 'voice')
      expect(refreshed[:consecutive_successes]).to eq(0)
      expect(refreshed[:consecutive_failures]).to eq(1)
    end

    context 'pain: 3 consecutive failures' do
      before do
        # Set confidence high so dampening to 0.29 is observable
        entry_key = 'alice:voice'
        described_class.store[entry_key][:confidence] = 0.8
      end

      it 'sets status to dampened' do
        3.times { described_class.record_outcome(id: entry[:id], outcome: :failure) }
        refreshed = described_class.for(identity: 'alice', domain: 'voice')
        expect(refreshed[:status]).to eq('dampened')
      end

      it 'floors confidence to 0.29' do
        3.times { described_class.record_outcome(id: entry[:id], outcome: :failure) }
        refreshed = described_class.for(identity: 'alice', domain: 'voice')
        expect(refreshed[:confidence]).to eq(0.29)
      end

      it 'resets consecutive counters' do
        3.times { described_class.record_outcome(id: entry[:id], outcome: :failure) }
        refreshed = described_class.for(identity: 'alice', domain: 'voice')
        expect(refreshed[:consecutive_failures]).to eq(0)
        expect(refreshed[:consecutive_successes]).to eq(0)
      end

      it 'emits gaia.behavior.reverted if Legion::Events is defined' do
        events_stub = Module.new
        allow(events_stub).to receive(:emit)
        stub_const('Legion::Events', events_stub)
        3.times { described_class.record_outcome(id: entry[:id], outcome: :failure) }
        expect(events_stub).to have_received(:emit).with('gaia.behavior.reverted', hash_including(id: entry[:id]))
      end
    end
  end

  # ---- lazy decay ----

  describe '.for with lazy decay' do
    it 'decays confidence after idle hours' do
      entry = described_class.crystallize(identity: 'alice', domain: 'decay_test', directive: 'test')
      original_conf = entry[:confidence]

      # Fake the last_reinforced_at to be 24 hours ago
      key = 'alice:decay_test'
      described_class.store[key][:last_reinforced_at] = Time.now.utc - (24 * 3600)

      refreshed = described_class.for(identity: 'alice', domain: 'decay_test')
      expect(refreshed[:confidence]).to be < original_conf
    end

    it 'resists decay more at high emotional intensity' do
      # Two synapses: same age, but different intensities
      described_class.crystallize(identity: 'alice', domain: 'low_intensity', directive: 'low')
      described_class.crystallize(identity: 'alice', domain: 'high_intensity', directive: 'high')

      past = Time.now.utc - (48 * 3600)
      described_class.store['alice:low_intensity'][:last_reinforced_at]    = past
      described_class.store['alice:low_intensity'][:emotional_intensity]   = 0.0
      described_class.store['alice:high_intensity'][:last_reinforced_at]   = past
      described_class.store['alice:high_intensity'][:emotional_intensity]  = 1.0

      low  = described_class.for(identity: 'alice', domain: 'low_intensity')[:confidence]
      high = described_class.for(identity: 'alice', domain: 'high_intensity')[:confidence]

      expect(high).to be > low
    end
  end

  # ---- .all_for ----

  describe '.all_for' do
    it 'returns only entries for the requested identity' do
      described_class.crystallize(identity: 'alice', domain: 'a', directive: 'd1')
      described_class.crystallize(identity: 'alice', domain: 'b', directive: 'd2')
      described_class.crystallize(identity: 'bob',   domain: 'a', directive: 'd3')

      result = described_class.all_for(identity: 'alice')
      expect(result.size).to eq(2)
      expect(result.map { |e| e[:identity] }.uniq).to eq(['alice'])
    end

    it 'returns empty array when no entries exist' do
      expect(described_class.all_for(identity: 'nobody')).to eq([])
    end
  end

  # ---- .erase_partner! ----

  describe '.erase_partner!' do
    it 'removes all entries for the identity' do
      described_class.crystallize(identity: 'alice', domain: 'a', directive: 'd1')
      described_class.crystallize(identity: 'alice', domain: 'b', directive: 'd2')
      described_class.crystallize(identity: 'bob',   domain: 'a', directive: 'd3')

      count = described_class.erase_partner!(identity: 'alice')
      expect(count).to eq(2)
      expect(described_class.all_for(identity: 'alice')).to be_empty
    end

    it 'leaves other identities untouched' do
      described_class.crystallize(identity: 'alice', domain: 'a', directive: 'd1')
      described_class.crystallize(identity: 'bob',   domain: 'a', directive: 'd2')

      described_class.erase_partner!(identity: 'alice')
      expect(described_class.all_for(identity: 'bob').size).to eq(1)
    end

    it 'returns 0 when no entries exist' do
      expect(described_class.erase_partner!(identity: 'ghost')).to eq(0)
    end
  end

  # ---- Tracker persistence ----

  describe 'Tracker' do
    subject(:tracker) { described_class::Tracker.new }

    before do
      described_class.crystallize(identity: 'alice', domain: 'tone', directive: 'friendly')
      described_class.mark_clean!
    end

    it 'is clean after mark_clean!' do
      expect(tracker.dirty?).to be false
    end

    it 'is dirty after crystallize' do
      described_class.crystallize(identity: 'bob', domain: 'style', directive: 'brief')
      expect(tracker.dirty?).to be true
    end

    it 'is clean again after mark_clean!' do
      described_class.crystallize(identity: 'bob', domain: 'style', directive: 'brief')
      tracker.mark_clean!
      expect(tracker.dirty?).to be false
    end

    describe '#to_apollo_entries' do
      it 'returns one entry per synapse' do
        described_class.crystallize(identity: 'charlie', domain: 'x', directive: 'd')
        entries = tracker.to_apollo_entries
        expect(entries.size).to be >= 2
      end

      it 'each entry has content, tags, confidence, access_scope' do
        entry = tracker.to_apollo_entries.first
        expect(entry).to include(:content, :tags, :confidence, :access_scope)
      end

      it 'tags include self-knowledge and behavior' do
        entry = tracker.to_apollo_entries.first
        expect(entry[:tags]).to include('self-knowledge', 'behavior')
      end

      it 'tags include partner identity tag' do
        entry = tracker.to_apollo_entries.find { |e| e[:tags].any? { |t| t.start_with?('partner:') } }
        expect(entry).not_to be_nil
      end
    end

    describe '#from_apollo' do
      it 'hydrates entries from apollo store' do
        # Build a store with a canned entry
        synapse_data = {
          id: 'test-uuid-1234-5678-9abc',
          identity: 'hydrated_user',
          domain: 'hydrated_domain',
          origin: 'emergent',
          confidence: 0.45,
          emotional_valence: 0.1,
          emotional_intensity: 0.2,
          consecutive_failures: 0,
          consecutive_successes: 2,
          directive: 'be helpful',
          evidence_trace_ids: [],
          status: 'active',
          last_applied_at: nil,
          last_reinforced_at: Time.now.utc.iso8601,
          created_at: Time.now.utc.iso8601
        }

        mock_store = instance_double('ApolloLocal')
        allow(mock_store).to receive(:query).and_return({
                                                          success: true,
                                                          results: [{ content: Legion::JSON.dump(synapse_data) }]
                                                        })

        described_class.reset!
        tracker.from_apollo(store: mock_store)

        entry = described_class.for(identity: 'hydrated_user', domain: 'hydrated_domain')
        expect(entry).not_to be_nil
        expect(entry[:confidence]).to be_within(0.001).of(0.45)
        expect(entry[:origin]).to eq('emergent')
      end

      it 'does nothing when store is nil' do
        expect { tracker.from_apollo(store: nil) }.not_to raise_error
      end
    end
  end
end
