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
end
