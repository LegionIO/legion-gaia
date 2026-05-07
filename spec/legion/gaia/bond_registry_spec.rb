# frozen_string_literal: true

RSpec.describe Legion::Gaia::BondRegistry do
  before { described_class.reset! }

  describe '.register' do
    context 'with bond: kwarg (new API)' do
      it 'registers a bond and stores :bond key' do
        described_class.register('esity', bond: :partner, priority: :primary)
        expect(described_class.bond('esity')).to eq(:partner)
      end

      it 'also stores :role key for backward compatibility' do
        described_class.register('esity', bond: :partner, priority: :primary)
        bond_entry = described_class.all_bonds.find { |b| b[:identity] == 'esity' }
        expect(bond_entry[:role]).to eq(:partner)
      end
    end

    context 'with role: kwarg (backward-compat alias)' do
      it 'accepts role: and stores bond correctly' do
        described_class.register('esity', role: :partner, priority: :primary)
        expect(described_class.bond('esity')).to eq(:partner)
      end

      it 'stores both :bond and :role keys' do
        described_class.register('esity', role: :partner, priority: :primary)
        bond_entry = described_class.all_bonds.find { |b| b[:identity] == 'esity' }
        expect(bond_entry[:bond]).to eq(:partner)
        expect(bond_entry[:role]).to eq(:partner)
      end
    end

    context 'with both bond: and role: provided' do
      it 'bond: takes precedence over role:' do
        described_class.register('esity', bond: :partner, role: :known, priority: :normal)
        expect(described_class.bond('esity')).to eq(:partner)
      end
    end

    context 'with neither bond: nor role: provided' do
      it 'defaults to :unknown' do
        described_class.register('esity')
        expect(described_class.bond('esity')).to eq(:unknown)
      end
    end

    it 'stores preferred and last channel metadata' do
      described_class.register('esity', bond: :partner, preferred_channel: :teams, last_channel: :slack)
      entry = described_class.all_bonds.find { |b| b[:identity] == 'esity' }
      expect(entry[:preferred_channel]).to eq(:teams)
      expect(entry[:last_channel]).to eq(:slack)
    end
  end

  describe '.bond' do
    it 'returns :unknown for unregistered identities' do
      expect(described_class.bond('nobody')).to eq(:unknown)
    end

    it 'returns the registered bond' do
      described_class.register('esity', bond: :partner, priority: :primary)
      expect(described_class.bond('esity')).to eq(:partner)
    end
  end

  describe '.role (backward-compat alias)' do
    it 'delegates to .bond' do
      described_class.register('esity', bond: :partner, priority: :primary)
      expect(described_class.role('esity')).to eq(:partner)
    end

    it 'returns :unknown for unregistered identities' do
      expect(described_class.role('nobody')).to eq(:unknown)
    end
  end

  describe '.partner?' do
    it 'returns true for registered partners' do
      described_class.register('esity', bond: :partner, priority: :primary)
      expect(described_class.partner?('esity')).to be true
    end

    it 'returns false for unknown identities' do
      expect(described_class.partner?('stranger')).to be false
    end

    it 'returns false for known non-partners' do
      described_class.register('colleague', bond: :known, priority: :normal)
      expect(described_class.partner?('colleague')).to be false
    end
  end

  describe '.all_bonds' do
    it 'returns all registered bonds' do
      described_class.register('esity', bond: :partner, priority: :primary)
      described_class.register('other', bond: :known, priority: :normal)
      bonds = described_class.all_bonds
      expect(bonds.size).to eq(2)
      identities = bonds.map { |b| b[:identity] }
      expect(identities).to include('esity', 'other')
    end

    it 'each entry contains :bond and :role keys' do
      described_class.register('esity', bond: :partner, priority: :primary)
      entry = described_class.all_bonds.first
      expect(entry).to have_key(:bond)
      expect(entry).to have_key(:role)
    end
  end

  describe 'thread safety (@bonds is Concurrent::Hash)' do
    it 'handles concurrent registrations without error' do
      threads = Array.new(20) do |i|
        Thread.new { described_class.register("user_#{i}", bond: :known) }
      end
      threads.each(&:join)
      expect(described_class.all_bonds.size).to eq(20)
    end
  end

  describe '.hydrate_from_apollo' do
    it 'loads partner identities from Apollo Local seed data using bond:' do
      stub_apollo = double('Apollo::Local')
      seed_content = "Identity keys: esity, miverso2\nBond type: partner, creator\nBond priority: primary"
      allow(stub_apollo).to receive(:query).and_return(
        success: true,
        results: [{ content: seed_content, tags: %w[partner bond self-knowledge] }]
      )
      described_class.hydrate_from_apollo(store: stub_apollo)
      expect(described_class.partner?('esity')).to be true
      expect(described_class.partner?('miverso2')).to be true
    end

    it 'restores channel identity and channel metadata from Apollo Local seed data' do
      stub_apollo = double('Apollo::Local')
      seed_content = "Identity keys: partner-uuid\nBond type: partner\n" \
                     "Channel identity: U_TEAMS_1\nPreferred channel: teams\nLast channel: slack"
      allow(stub_apollo).to receive(:query).and_return(
        success: true,
        results: [{ content: seed_content, tags: %w[partner bond self-knowledge] }]
      )

      described_class.hydrate_from_apollo(store: stub_apollo)
      entry = described_class.partner_entry

      expect(entry[:channel_identity]).to eq('U_TEAMS_1')
      expect(entry[:preferred_channel]).to eq(:teams)
      expect(entry[:last_channel]).to eq(:slack)
    end

    it 'handles missing Apollo gracefully' do
      expect { described_class.hydrate_from_apollo(store: nil) }.not_to raise_error
      expect(described_class.all_bonds).to be_empty
    end
  end

  describe 'multiple identity keys for same partner' do
    it 'maps multiple identities to the same bond' do
      described_class.register('esity', bond: :partner, priority: :primary)
      described_class.register('miverso2', bond: :partner, priority: :primary)
      expect(described_class.partner?('esity')).to be true
      expect(described_class.partner?('miverso2')).to be true
    end
  end

  describe '.partner_entry (§9.6 deterministic selection)' do
    it 'returns nil when no partner bonds exist' do
      described_class.register('colleague', bond: :known)
      expect(described_class.partner_entry).to be_nil
    end

    it 'returns the single partner entry when only one exists' do
      described_class.register('esity', bond: :partner)
      expect(described_class.partner_entry[:identity]).to eq('esity')
    end

    it 'prefers an entry with channel_identity over one without' do
      described_class.register('uuid-primary', bond: :partner, priority: :primary)
      described_class.register('uuid-channel', bond: :partner, channel_identity: 'U_SLACK_999')
      entry = described_class.partner_entry
      expect(entry[:identity]).to eq('uuid-channel')
    end

    it 'prefers priority :primary over :normal when neither has channel_identity' do
      described_class.register('normal-id', bond: :partner, priority: :normal)
      described_class.register('primary-id', bond: :partner, priority: :primary)
      entry = described_class.partner_entry
      expect(entry[:identity]).to eq('primary-id')
    end

    it 'falls back to earliest-registered entry when no channel_identity or primary priority match' do
      described_class.register('second-id', bond: :partner, priority: :normal)
      sleep(0.001)
      described_class.register('first-id', bond: :partner, priority: :normal)
      entry = described_class.partner_entry
      # 'second-id' registered first (:since is earlier), so it wins the tie-breaker
      expect(entry[:identity]).to eq('second-id')
    end
  end

  describe '.channel_identity (§9.6)' do
    it 'returns the stored channel_identity when present' do
      described_class.register('a1b2c3d4-0000-0000-0000-aabbccddeeff',
                               bond: :partner, channel_identity: 'U12345')
      expect(described_class.channel_identity('a1b2c3d4-0000-0000-0000-aabbccddeeff')).to eq('U12345')
    end

    it 'falls back to :identity when no channel_identity was stored' do
      described_class.register('esity', bond: :partner, priority: :primary)
      expect(described_class.channel_identity('esity')).to eq('esity')
    end

    it 'returns nil for unregistered identities' do
      expect(described_class.channel_identity('nobody')).to be_nil
    end

    it 'stores channel_identity in the bond hash entry' do
      described_class.register('uuid-1', bond: :partner, channel_identity: 'T09876')
      entry = described_class.all_bonds.find { |b| b[:identity] == 'uuid-1' }
      expect(entry[:channel_identity]).to eq('T09876')
    end

    it 'stores nil channel_identity when not provided' do
      described_class.register('esity', bond: :partner)
      entry = described_class.all_bonds.find { |b| b[:identity] == 'esity' }
      expect(entry[:channel_identity]).to be_nil
    end
  end

  describe '.record_channel' do
    it 'updates the last seen channel for an existing bond' do
      described_class.register('aad-1', bond: :partner)
      described_class.record_channel('aad-1', channel_id: :teams, channel_identity: 'teams-user-1')
      entry = described_class.partner_entry

      expect(entry[:last_channel]).to eq(:teams)
      expect(entry[:preferred_channel]).to eq(:teams)
      expect(entry[:channel_identity]).to eq('teams-user-1')
    end

    it 'stores an updated entry instead of mutating the previous hash in place' do
      described_class.register('aad-1', bond: :partner)
      original_entry = described_class.all_bonds.find { |entry| entry[:identity] == 'aad-1' }

      updated_entry = described_class.record_channel('aad-1', channel_id: :teams)

      expect(updated_entry).not_to equal(original_entry)
      expect(original_entry[:last_channel]).to be_nil
      expect(updated_entry[:last_channel]).to eq(:teams)
    end
  end
end
