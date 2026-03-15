# frozen_string_literal: true

RSpec.describe Legion::Gaia do
  before do
    stub_const('Legion::Logging', Module.new do
      def self.debug(_msg); end
      def self.info(_msg); end
      def self.warn(_msg); end
      def self.error(_msg); end
    end)
  end

  after do
    described_class.shutdown if described_class.started?
  end

  describe '.boot' do
    it 'starts GAIA and sets started? to true' do
      described_class.boot
      expect(described_class.started?).to be true
    end

    it 'creates a sensory buffer' do
      described_class.boot
      expect(described_class.sensory_buffer).to be_a(Legion::Gaia::SensoryBuffer)
    end

    it 'creates a registry' do
      described_class.boot
      expect(described_class.registry).to be_a(Legion::Gaia::Registry)
    end
  end

  describe '.shutdown' do
    it 'sets started? to false' do
      described_class.boot
      described_class.shutdown
      expect(described_class.started?).to be false
    end

    it 'clears sensory buffer and registry' do
      described_class.boot
      described_class.shutdown
      expect(described_class.sensory_buffer).to be_nil
      expect(described_class.registry).to be_nil
    end
  end

  describe '.heartbeat' do
    it 'returns error when not started' do
      result = described_class.heartbeat
      expect(result[:error]).to eq(:not_started)
    end

    it 'returns error when lex-tick not available' do
      described_class.boot
      result = described_class.heartbeat
      expect(result[:error]).to eq(:no_tick_extension)
    end
  end

  describe '.status' do
    it 'returns started: false when not booted' do
      expect(described_class.status).to eq({ started: false })
    end

    it 'returns full status when booted' do
      described_class.boot
      status = described_class.status
      expect(status[:started]).to be true
      expect(status).to have_key(:extensions_loaded)
      expect(status).to have_key(:wired_phases)
      expect(status).to have_key(:buffer_depth)
    end
  end

  describe '.settings' do
    it 'returns default settings hash' do
      settings = described_class.settings
      expect(settings).to be_a(Hash)
      expect(settings[:heartbeat_interval]).to eq(1)
      expect(settings[:channels]).to have_key(:cli)
    end
  end

  describe 'VERSION' do
    it 'has a version number' do
      expect(Legion::Gaia::VERSION).not_to be_nil
    end
  end
end
