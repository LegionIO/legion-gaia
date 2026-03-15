# frozen_string_literal: true

RSpec.describe Legion::Gaia::Settings do
  describe '.default' do
    subject(:settings) { described_class.default }

    it 'returns a hash' do
      expect(settings).to be_a(Hash)
    end

    it 'has heartbeat_interval of 1' do
      expect(settings[:heartbeat_interval]).to eq(1)
    end

    it 'has cli channel enabled by default' do
      expect(settings.dig(:channels, :cli, :enabled)).to be true
    end

    it 'has teams channel disabled by default' do
      expect(settings.dig(:channels, :teams, :enabled)).to be false
    end

    it 'has router mode disabled by default' do
      expect(settings.dig(:router, :mode)).to be false
    end

    it 'has session ttl of 86400' do
      expect(settings.dig(:session, :ttl)).to eq(86_400)
    end
  end
end
