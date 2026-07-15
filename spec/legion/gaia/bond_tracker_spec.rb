# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/bond_store'
require 'legion/gaia/bond_registry'
require 'legion/gaia/bond_tracker'

RSpec.describe Legion::Gaia::BondTracker do
  before do
    Legion::Gaia::BondRegistry.reset!
    described_class.instance_variable_set(:@dirty, false)
  end

  after { Legion::Gaia::BondRegistry.reset! }

  describe '.dirty?' do
    it 'returns false by default' do
      expect(described_class).not_to be_dirty
    end
  end

  describe '.dirty!' do
    it 'sets dirty flag' do
      described_class.dirty!
      expect(described_class).to be_dirty
    end
  end

  describe '.mark_clean!' do
    it 'clears dirty flag' do
      described_class.dirty!
      described_class.mark_clean!
      expect(described_class).not_to be_dirty
    end
  end

  describe '.to_apollo_entries' do
    it 'returns empty array when no dirty stores' do
      entries = described_class.to_apollo_entries
      expect(entries).to be_empty
    end
  end
end
