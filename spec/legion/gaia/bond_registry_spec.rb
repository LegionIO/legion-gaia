# frozen_string_literal: true

RSpec.describe Legion::Gaia::BondRegistry do
  before { described_class.reset! }

  describe '.register' do
    context 'with bond: kwarg' do
      it 'registers a bond and stores :bond key' do
        described_class.register('test-id', bond: :partner, priority: :primary)
        expect(described_class.bond('test-id')).to eq(:partner)
      end

      it 'also stores :role key for backward compatibility' do
        described_class.register('test-id', bond: :partner)
        entry = described_class.all_bonds.find { |b| b[:identity] == 'test-id' }
        expect(entry[:role]).to eq(:partner)
      end
    end

    context 'with role: kwarg (backward-compat alias)' do
      it 'accepts role: and stores bond correctly' do
        described_class.register('test-id', role: :partner)
        expect(described_class.bond('test-id')).to eq(:partner)
      end
    end

    context 'with neither bond: nor role:' do
      it 'defaults to :unknown' do
        described_class.register('test-id')
        expect(described_class.bond('test-id')).to eq(:unknown)
      end
    end

    it 'stores preferred and last channel metadata' do
      described_class.register('test-id', bond: :known, preferred_channel: :teams, last_channel: :slack)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:preferred_channel]).to eq(:teams)
      expect(entry[:last_channel]).to eq(:slack)
    end

    it 'defaults partner bond origin to :provisional' do
      described_class.register('test-id', bond: :partner)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:origin]).to eq(:provisional)
    end

    it 'defaults non-partner bond origin to nil' do
      described_class.register('test-id', bond: :known)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:origin]).to be_nil
    end

    it 'defaults strength to 0.0' do
      described_class.register('test-id', bond: :partner)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to eq(0.0)
    end

    it 'accepts explicit strength' do
      described_class.register('test-id', bond: :partner, strength: 0.75)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to eq(0.75)
    end

    it 'stores flow fields' do
      described_class.register('test-id', bond: :partner, origin: :earned, strength: 0.9,
                                          reinforcement_count: 5, last_reinforced: Time.new)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:origin]).to eq(:earned)
      expect(entry[:strength]).to eq(0.9)
      expect(entry[:reinforcement_count]).to eq(5)
      expect(entry[:last_reinforced]).not_to be_nil
    end
  end

  describe '.bond' do
    it 'returns :unknown for unregistered identities' do
      expect(described_class.bond('nobody')).to eq(:unknown)
    end

    it 'returns the registered bond' do
      described_class.register('test-id', bond: :partner)
      expect(described_class.bond('test-id')).to eq(:partner)
    end
  end

  describe '.role' do
    it 'delegates to .bond' do
      described_class.register('test-id', bond: :partner)
      expect(described_class.role('test-id')).to eq(:partner)
    end
  end

  describe '.partner?' do
    it 'returns true when bond is :partner and strength exceeds threshold' do
      described_class.register('test-id', bond: :partner, strength: 0.75)
      expect(described_class.partner?('test-id')).to be true
    end

    it 'returns false when bond is :partner but strength below threshold' do
      described_class.register('test-id', bond: :partner, strength: 0.3)
      expect(described_class.partner?('test-id')).to be false
    end

    it 'returns false for unknown identities' do
      expect(described_class.partner?('stranger')).to be false
    end

    it 'returns false for known non-partners' do
      described_class.register('colleague', bond: :known, strength: 0.9)
      expect(described_class.partner?('colleague')).to be false
    end

    it 'returns false when strength exactly zero' do
      described_class.register('test-id', bond: :partner, strength: 0.0)
      expect(described_class.partner?('test-id')).to be false
    end
  end

  describe '.partner_threshold' do
    it 'uses gaia settings value' do
      expect(described_class.partner_threshold).to eq(0.6)
    end
  end

  describe '.all_bonds' do
    it 'returns all registered bonds' do
      described_class.register('a', bond: :partner, strength: 0.7)
      described_class.register('b', bond: :known)
      bonds = described_class.all_bonds
      expect(bonds.size).to eq(2)
      expect(bonds.map { |b| b[:identity] }).to contain_exactly('a', 'b')
    end

    it 'each entry contains :bond and :role keys' do
      described_class.register('test-id', bond: :partner)
      entry = described_class.all_bonds.first
      expect(entry).to have_key(:bond)
      expect(entry).to have_key(:role)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent registrations without error' do
      threads = Array.new(20) do |i|
        Thread.new { described_class.register("user_#{i}", bond: :known) }
      end
      threads.each(&:join)
      expect(described_class.all_bonds.size).to eq(20)
    end
  end

  describe '.reinforce' do
    it 'increases strength with diminishing returns' do
      described_class.register('test-id', bond: :partner, strength: 0.0)
      described_class.reinforce('test-id')
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to be > 0.0
      expect(entry[:strength]).to be <= 1.0
    end

    it 'applies direct_address weight' do
      described_class.register('test-id', bond: :partner, strength: 0.2)
      described_class.reinforce('test-id', direct_address: true)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      # Base delta: 0.1 * (1 - 0.2) = 0.08; with direct_address: 0.08 * 1.5 = 0.12
      expect(entry[:strength]).to eq(0.2 + (0.1 * 0.8 * 1.5))
    end

    it 'applies new_channel (corroboration) weight' do
      described_class.register('test-id', bond: :partner, strength: 0.2)
      described_class.reinforce('test-id', new_channel: true)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      # Base delta: 0.1 * 0.8 = 0.08; with corroboration: 0.08 * 1.3 = 0.104
      expect(entry[:strength]).to eq(0.2 + (0.1 * 0.8 * 1.3))
    end

    it 'caps strength at 1.0' do
      described_class.register('test-id', bond: :partner, strength: 0.99)
      # Multi-reinforce to push toward 1.0 (diminishing returns)
      50.times { described_class.reinforce('test-id', multiplier: 3.0) }
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to be_within(0.001).of(1.0)
    end

    it 'applies multiplier' do
      described_class.register('test-id', bond: :partner, strength: 0.2)
      described_class.reinforce('test-id', multiplier: 3.0)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      # delta: 0.1 * 0.8 * 3.0 = 0.24, new = 0.44
      expect(entry[:strength]).to be_within(0.001).of(0.44)
    end

    it 'increments reinforcement_count' do
      described_class.register('test-id', bond: :partner)
      3.times { described_class.reinforce('test-id') }
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:reinforcement_count]).to eq(3)
    end

    it 'sets last_reinforced timestamp' do
      described_class.register('test-id', bond: :partner)
      described_class.reinforce('test-id')
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:last_reinforced]).not_to be_nil
    end

    it 'promotes provisional to earned on threshold crossing' do
      described_class.register('test-id', bond: :partner, strength: 0.55)
      described_class.reinforce('test-id')
      # delta: 0.1 * 0.45 = 0.045 → new_strength = 0.595 (still below 0.6)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:origin]).to eq(:provisional)
      # Reinforce again to push over
      described_class.reinforce('test-id')
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      # delta: 0.1 * (1 - 0.595) = 0.0405 → 0.6355
      expect(entry[:origin]).to eq(:earned)
    end

    it 'does nothing for unregistered identity' do
      result = described_class.reinforce('ghost')
      expect(result).to be_nil
    end
  end

  describe '.apply_decay' do
    it 'decreases strength by decay rate' do
      described_class.register('test-id', bond: :partner, strength: 0.8)
      # Default rate 0.002
      described_class.apply_decay
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to eq((0.8 * 0.998).round(10))
    end

    it 'does not go below 0.0' do
      described_class.register('test-id', bond: :partner, strength: 0.001)
      200.times { described_class.apply_decay }
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:strength]).to be >= 0.0
    end

    it 'does not decay entries without strength' do
      described_class.register('test-id', bond: :known)
      expect { described_class.apply_decay }.not_to raise_error
    end
  end

  describe '.hydrate_from_apollo' do
    context 'with structured JSON entries' do
      it 'loads bond entries from Apollo and sets origin to :hydrated' do
        stub_store = double('store')
        entry_data = {
          identity: 'test-id',
          bond: :partner,
          priority: :primary,
          strength: 0.85,
          origin: :earned,
          reinforcement_count: 10
        }
        allow(stub_store).to receive(:query).with(text: 'bond', tags: described_class::TO_APOLLO_TAGS)
                                            .and_return(
                                              success: true,
                                              results: [{ content: Legion::JSON.dump(entry_data),
                                                          tags: described_class::TO_APOLLO_TAGS }]
                                            )
        allow(stub_store).to receive(:query).with(text: 'partner', tags: %w[self-knowledge])
                                            .and_return(success: true, results: [])

        described_class.hydrate_from_apollo(store: stub_store)
        expect(described_class.bond('test-id')).to eq(:partner)
        expect(described_class.partner?('test-id')).to be true
        entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
        expect(entry[:origin]).to eq(:hydrated)
        expect(entry[:strength]).to eq(0.85)
      end
    end

    context 'with legacy markdown entries' do
      it 'falls back to markdown regex parse' do
        stub_store = double('store')
        # No JSON entries
        allow(stub_store).to receive(:query).with(text: 'bond', tags: described_class::TO_APOLLO_TAGS)
                                            .and_return(success: true, results: [])
        # Legacy search
        seed_content = "Identity keys: legacy-id\nBond type: partner\nBond priority: primary"
        allow(stub_store).to receive(:query).with(text: 'partner', tags: ['self-knowledge'])
                                            .and_return(success: true, results: [{ content: seed_content,
                                                                                   tags: ['self-knowledge'] }])

        described_class.hydrate_from_apollo(store: stub_store)
        expect(described_class.bond('legacy-id')).to eq(:partner)
      end
    end

    it 'handles nil store gracefully' do
      expect { described_class.hydrate_from_apollo(store: nil) }.not_to raise_error
    end
  end

  describe '.from_apollo' do
    it 'loads entries and sets origin to :hydrated' do
      stub_store = double('store')
      entry_data = { identity: 'fa-id', bond: :partner, strength: 0.9, origin: :earned }
      allow(stub_store).to receive(:query)
        .with(text: 'bond', tags: described_class::TO_APOLLO_TAGS)
        .and_return(success: true, results: [{ content: Legion::JSON.dump(entry_data) }])

      described_class.from_apollo(store: stub_store)
      entry = described_class.all_bonds.find { |e| e[:identity] == 'fa-id' }
      expect(entry[:origin]).to eq(:hydrated)
      expect(entry[:strength]).to eq(0.9)
    end
  end

  describe '.partner_entry' do
    it 'returns nil when no partner bonds above threshold' do
      described_class.register('test-id', bond: :partner, strength: 0.1)
      expect(described_class.partner_entry).to be_nil
    end

    it 'returns the partner entry when above threshold' do
      described_class.register('test-id', bond: :partner, strength: 0.7)
      expect(described_class.partner_entry[:identity]).to eq('test-id')
    end

    it 'prefers highest strength first' do
      described_class.register('weak', bond: :partner, strength: 0.65)
      sleep 0.001
      described_class.register('strong', bond: :partner, strength: 0.9)
      entry = described_class.partner_entry
      expect(entry[:identity]).to eq('strong')
    end

    it 'prefers entry with channel_identity among equal strength' do
      described_class.register('no-ch', bond: :partner, strength: 0.8)
      described_class.register('with-ch', bond: :partner, channel_identity: 'U123', strength: 0.8)
      entry = described_class.partner_entry
      expect(entry[:identity]).to eq('with-ch')
    end

    it 'prefers primary priority as tiebreaker' do
      described_class.register('normal', bond: :partner, priority: :normal, strength: 0.7)
      described_class.register('primary', bond: :partner, priority: :primary, strength: 0.7)
      entry = described_class.partner_entry
      expect(entry[:identity]).to eq('primary')
    end
  end

  describe '.channel_identity' do
    it 'returns stored channel_identity' do
      described_class.register('uuid-1', bond: :partner, channel_identity: 'U12345')
      expect(described_class.channel_identity('uuid-1')).to eq('U12345')
    end

    it 'falls back to identity when no channel_identity' do
      described_class.register('test-id', bond: :partner)
      expect(described_class.channel_identity('test-id')).to eq('test-id')
    end

    it 'returns nil for unregistered identities' do
      expect(described_class.channel_identity('nobody')).to be_nil
    end
  end

  describe '.record_channel' do
    it 'updates last_channel and preferred_channel' do
      described_class.register('test-id', bond: :partner)
      described_class.record_channel('test-id', channel_id: :teams, channel_identity: 't1')
      entry = described_class.all_bonds.find { |e| e[:identity] == 'test-id' }
      expect(entry[:last_channel]).to eq(:teams)
      expect(entry[:preferred_channel]).to eq(:teams)
      expect(entry[:channel_identity]).to eq('t1')
    end
  end

  describe '.dirty? and .mark_clean!' do
    it 'is dirty after register' do
      described_class.register('test-id', bond: :partner)
      expect(described_class.dirty?).to be true
    end

    it 'is clean after mark_clean!' do
      described_class.register('test-id', bond: :partner)
      described_class.mark_clean!
      expect(described_class.dirty?).to be false
    end

    it 'is dirty after reinforce' do
      described_class.register('test-id', bond: :partner)
      described_class.mark_clean!
      described_class.reinforce('test-id')
      expect(described_class.dirty?).to be true
    end
  end

  describe '.to_apollo_entries' do
    it 'returns array of upsert-ready hashes' do
      described_class.register('test-id', bond: :partner, strength: 0.8)
      entries = described_class.to_apollo_entries
      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry[:content]).to be_a(String)
      expect(entry[:tags]).to eq(%w[self-knowledge bond])
      expect(entry[:confidence]).to eq(0.8)
      expect(entry[:access_scope]).to eq('local')
    end

    it 'content is JSON-parseable roundtrip' do
      described_class.register('rt-id', bond: :partner, strength: 0.75, origin: :earned)
      entry = described_class.to_apollo_entries.first
      parsed = Legion::JSON.load(entry[:content])
      expect(parsed[:identity]).to eq('rt-id')
      expect(parsed[:bond]).to eq('partner')
      expect(parsed[:strength]).to eq(0.75)
      expect(parsed[:origin]).to eq('earned')
    end
  end

  describe '.erase_partner!' do
    it 'removes the target identity and leaves others untouched' do
      described_class.register('X', bond: :partner, strength: 0.7)
      described_class.register('Y', bond: :known, strength: 0.5)
      described_class.erase_partner!(identity: 'X')
      expect(described_class.bond('X')).to eq(:unknown)
      expect(described_class.bond('Y')).to eq(:known)
    end

    it 'returns erased: true for existing identity' do
      described_class.register('X', bond: :partner, strength: 0.7)
      result = described_class.erase_partner!(identity: 'X')
      expect(result).to eq({ erased: true, identity: 'X' })
    end

    it 'makes bond(:X) return :unknown after erasure' do
      described_class.register('X', bond: :partner)
      described_class.erase_partner!(identity: 'X')
      expect(described_class.bond('X')).to eq(:unknown)
    end

    it 'makes partner?(:X) return false after erasure' do
      described_class.register('X', bond: :partner, strength: 0.9)
      described_class.erase_partner!(identity: 'X')
      expect(described_class.partner?('X')).to be false
    end

    it 'marks the registry dirty after erasure' do
      described_class.register('X', bond: :partner)
      described_class.mark_clean!
      described_class.erase_partner!(identity: 'X')
      expect(described_class.dirty?).to be true
    end

    it 'is idempotent — erasing a non-existent identity does not raise' do
      expect { described_class.erase_partner!(identity: 'ghost') }.not_to raise_error
    end

    it 'returns erased: false for non-existent identity' do
      result = described_class.erase_partner!(identity: 'ghost')
      expect(result).to eq({ erased: false, identity: 'ghost' })
    end

    context 'when Legion::Events is defined' do
      it 'emits gaia.bond.erased event' do
        described_class.register('X', bond: :partner, strength: 0.7)
        events_stub = double('Legion::Events')
        stub_const('Legion::Events', events_stub)
        allow(events_stub).to receive(:respond_to?).with(:emit).and_return(true)
        expect(events_stub).to receive(:emit).with('gaia.bond.erased', identity: 'X')
        described_class.erase_partner!(identity: 'X')
      end
    end
  end

  describe '.reset!' do
    it 'clears bonds and dirty flag' do
      described_class.register('test-id', bond: :partner, strength: 0.7)
      described_class.reset!
      expect(described_class.all_bonds).to be_empty
      expect(described_class.dirty?).to be false
    end
  end
end
