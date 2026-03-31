# frozen_string_literal: true

RSpec.describe Legion::Gaia::BondRegistry do
  before { described_class.reset! }

  describe '.register' do
    it 'registers a bond with role and priority' do
      described_class.register('esity', role: :partner, priority: :primary)
      expect(described_class.role('esity')).to eq(:partner)
    end
  end

  describe '.partner?' do
    it 'returns true for registered partners' do
      described_class.register('esity', role: :partner, priority: :primary)
      expect(described_class.partner?('esity')).to be true
    end

    it 'returns false for unknown identities' do
      expect(described_class.partner?('stranger')).to be false
    end

    it 'returns false for known non-partners' do
      described_class.register('colleague', role: :known, priority: :normal)
      expect(described_class.partner?('colleague')).to be false
    end
  end

  describe '.role' do
    it 'returns :unknown for unregistered identities' do
      expect(described_class.role('nobody')).to eq(:unknown)
    end

    it 'returns the registered role' do
      described_class.register('esity', role: :partner, priority: :primary)
      expect(described_class.role('esity')).to eq(:partner)
    end
  end

  describe '.all_bonds' do
    it 'returns all registered bonds' do
      described_class.register('esity', role: :partner, priority: :primary)
      described_class.register('other', role: :known, priority: :normal)
      bonds = described_class.all_bonds
      expect(bonds.size).to eq(2)
      expect(bonds.first[:identity]).to eq('esity')
    end
  end

  describe '.hydrate_from_apollo' do
    it 'loads partner identities from Apollo Local seed data' do
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
    it 'maps multiple identities to the same role' do
      described_class.register('esity', role: :partner, priority: :primary)
      described_class.register('miverso2', role: :partner, priority: :primary)
      expect(described_class.partner?('esity')).to be true
      expect(described_class.partner?('miverso2')).to be true
    end
  end
end
