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

    it 'delivers a Teams response only to its explicit tenant and conversation' do
      teams = Legion::Gaia::Channels::TeamsAdapter.new(default_conversation_id: 'wrong-destination')
      teams.start
      teams.conversation_store.store(conversation_id: 'conv-a', tenant_id: 'tenant-a', service_url: 'https://tenant-a.example')
      teams.conversation_store.store(conversation_id: 'conv-a', tenant_id: 'tenant-b', service_url: 'https://tenant-b.example')
      registry.register(teams)
      client = double('TeamsClient')
      stub_const('Legion::Extensions::MicrosoftTeams::Client', double('TeamsClientClass', new: client))
      expect(client).to receive(:send_text).with(service_url: 'https://tenant-b.example',
                                                 conversation_id: 'conv-a', text: 'private')
                                           .and_return({ delivered: true })
      frame = Legion::Gaia::OutputFrame.new(content: 'private', channel_id: :teams,
                                            metadata: { conversation_id: 'conv-a', tenant_id: 'tenant-b' })
      expect(registry.deliver(frame)[:delivered]).to be true
      missing = Legion::Gaia::OutputFrame.new(content: 'private', channel_id: :teams)
      expect(registry.deliver(missing)).to include(delivered: false, error: :no_target_conversation)
      unscoped = missing.with(metadata: { conversation_id: 'conv-a' })
      expect(registry.deliver(unscoped)).to include(delivered: false, error: :no_target_tenant)
    end

    it 'routes an actual proactive frame to its user rather than the channel default' do
      teams = Legion::Gaia::Channels::TeamsAdapter.new(default_conversation_id: 'wrong-destination')
      teams.start
      %w[alice bob].each do |user|
        teams.conversation_store.store(conversation_id: "#{user}-dm", tenant_id: 'tenant', user_id: user,
                                       service_url: 'https://tenant.example', conversation_type: 'personal')
      end
      registry.register(teams)
      client = double('TeamsClient')
      stub_const('Legion::Extensions::MicrosoftTeams::Client', double('TeamsClientClass', new: client))
      expect(client).to receive(:send_text).with(service_url: 'https://tenant.example',
                                                 conversation_id: 'bob-dm', text: 'private')
                                           .and_return({ delivered: true })
      frame = Legion::Gaia::OutputFrame.new(content: 'private', channel_id: :teams,
                                            metadata: { proactive: true, target_user: 'bob', tenant_id: 'tenant' })
      expect(registry.deliver(frame)[:delivered]).to be true
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
