# frozen_string_literal: true

RSpec.describe Legion::Gaia::ChannelRegistry do
  subject(:registry) { described_class.new }

  let(:cli_adapter) { Legion::Gaia::Channels::CliAdapter.new }

  describe '#register / #adapter_for' do
    it 'registers and retrieves an adapter' do
      registry.register(cli_adapter)
      expect(registry.adapter_for(:cli)).to eq(cli_adapter)
    end
  end

  describe '#unregister' do
    it 'removes an adapter and stops it' do
      cli_adapter.start
      registry.register(cli_adapter)
      removed = registry.unregister(:cli)
      expect(removed).to eq(cli_adapter)
      expect(cli_adapter.started?).to be false
      expect(registry.adapter_for(:cli)).to be_nil
    end

    it 'returns nil for unknown channel' do
      expect(registry.unregister(:unknown)).to be_nil
    end
  end

  describe '#active_channels' do
    it 'returns registered channel ids' do
      registry.register(cli_adapter)
      expect(registry.active_channels).to eq([:cli])
    end
  end

  describe '#active_adapters' do
    it 'returns only started adapters' do
      registry.register(cli_adapter)
      expect(registry.active_adapters).to eq([])
      cli_adapter.start
      expect(registry.active_adapters).to eq([cli_adapter])
    end
  end

  describe '#size' do
    it 'returns adapter count' do
      expect(registry.size).to eq(0)
      registry.register(cli_adapter)
      expect(registry.size).to eq(1)
    end
  end

  describe '#deliver' do
    let(:frame) { Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :cli) }

    it 'delivers through the correct adapter' do
      cli_adapter.start
      registry.register(cli_adapter)
      result = registry.deliver(frame)
      expect(result[:delivered]).to be true
      expect(cli_adapter.last_output).to eq('hello')
    end

    it 'returns failure for unknown channel' do
      result = registry.deliver(frame)
      expect(result[:delivered]).to be false
      expect(result[:reason]).to eq(:no_adapter)
    end

    it 'returns failure for stopped adapter' do
      registry.register(cli_adapter)
      result = registry.deliver(frame)
      expect(result[:delivered]).to be false
      expect(result[:reason]).to eq(:adapter_stopped)
    end
  end

  describe '#start_all / #stop_all' do
    it 'starts and stops all adapters' do
      registry.register(cli_adapter)
      registry.start_all
      expect(cli_adapter.started?).to be true
      registry.stop_all
      expect(cli_adapter.started?).to be false
    end
  end
end
