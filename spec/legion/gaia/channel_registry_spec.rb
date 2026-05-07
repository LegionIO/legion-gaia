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

    it 'propagates adapter delivery failures' do
      failing_adapter = instance_double(Legion::Gaia::ChannelAdapter,
                                        channel_id: :cli,
                                        started?: true)
      allow(failing_adapter).to receive(:translate_outbound).with(frame).and_return('hello')
      allow(failing_adapter).to receive(:deliver).with('hello').and_return({ error: :network_error })
      registry.register(failing_adapter)

      result = registry.deliver(frame)
      expect(result[:delivered]).to be false
      expect(result[:error]).to eq(:network_error)
      expect(result[:channel_id]).to eq(:cli)
    end

    it 'passes conversation_id to adapters that accept it' do
      teams_adapter = Legion::Gaia::Channels::TeamsAdapter.new
      teams_adapter.start
      frame = Legion::Gaia::OutputFrame.new(
        content: 'hello',
        channel_id: :teams,
        metadata: { conversation_id: 'conv-1' }
      )

      registry.register(teams_adapter)
      allow(teams_adapter).to receive(:translate_outbound).with(frame).and_return({ type: 'text', text: 'hello' })
      allow(teams_adapter).to receive(:deliver).with({ type: 'text', text: 'hello' },
                                                     conversation_id: 'conv-1').and_return({ delivered: true })

      result = registry.deliver(frame)
      expect(result[:delivered]).to be true
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
