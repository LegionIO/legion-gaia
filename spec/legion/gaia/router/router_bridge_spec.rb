# frozen_string_literal: true

RSpec.describe Legion::Gaia::Router::RouterBridge do
  let(:channel_registry) { Legion::Gaia::ChannelRegistry.new }
  let(:cli_adapter) do
    adapter = Legion::Gaia::Channels::CliAdapter.new
    adapter.start
    adapter
  end

  subject(:bridge) { described_class.new(channel_registry: channel_registry) }

  before do
    channel_registry.register(cli_adapter)
  end

  describe '#start / #stop' do
    it 'tracks started state' do
      expect(bridge.started?).to be false
      bridge.start
      expect(bridge.started?).to be true
      bridge.stop
      expect(bridge.started?).to be false
    end
  end

  describe '#route_inbound' do
    let(:input_frame) do
      Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :teams,
        auth_context: { aad_object_id: 'oid-1', identity: 'oid-1' }
      )
    end

    it 'returns not_started when bridge not started' do
      result = bridge.route_inbound(input_frame)
      expect(result[:routed]).to be false
      expect(result[:reason]).to eq(:not_started)
    end

    context 'when started' do
      before { bridge.start }

      it 'returns worker_not_found when no route exists' do
        result = bridge.route_inbound(input_frame)
        expect(result[:routed]).to be false
        expect(result[:reason]).to eq(:worker_not_found)
        expect(result[:queued]).to be true
        expect(Legion::Gaia::OfflineHandler.pending_count('oid-1')).to eq(1)
      end

      it 'routes to registered worker' do
        bridge.worker_routing.register(identity: 'oid-1', worker_id: 'worker-a')
        result = bridge.route_inbound(input_frame)
        expect(result[:routed]).to be true
        expect(result[:worker_id]).to eq('worker-a')
        expect(result[:transport]).to eq(:mock)
      end
    end
  end

  describe '#route_outbound' do
    let(:payload) do
      {
        id: 'frame-1',
        content: 'response text',
        content_type: :text,
        channel_id: :cli,
        metadata: {}
      }
    end

    it 'returns not_started when bridge not started' do
      result = bridge.route_outbound(payload)
      expect(result[:delivered]).to be false
    end

    context 'when started' do
      before { bridge.start }

      it 'delivers through channel adapter' do
        result = bridge.route_outbound(payload)
        expect(result[:delivered]).to be true
        expect(result[:channel_id]).to eq(:cli)
      end

      it 'marks adapter error hashes as undelivered' do
        failing_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter,
                                          channel_id: :teams,
                                          started?: true)
        channel_registry.register(failing_adapter)
        failing_payload = payload.merge(channel_id: :teams, metadata: { conversation_id: 'conv-1' })

        allow(failing_adapter).to receive(:translate_outbound).and_return({ type: 'text', text: 'response text' })
        allow(failing_adapter).to receive(:deliver).with({ type: 'text', text: 'response text' },
                                                         conversation_id: 'conv-1').and_return(
                                                           { error: :no_conversation_reference }
                                                         )

        result = bridge.route_outbound(failing_payload)
        expect(result[:delivered]).to be false
        expect(result[:error]).to eq(:no_conversation_reference)
        expect(result[:channel_id]).to eq(:teams)
        expect(result[:frame_id]).to eq('frame-1')
      end

      it 'returns no_adapter for unknown channel' do
        result = bridge.route_outbound(payload.merge(channel_id: :unknown))
        expect(result[:delivered]).to be false
        expect(result[:reason]).to eq(:no_adapter)
      end

      it 'returns no_adapter for channel without adapter' do
        result = bridge.route_outbound({ content: 'x', channel_id: :nonexistent, content_type: :text })
        expect(result[:delivered]).to be false
        expect(result[:reason]).to eq(:no_adapter)
      end
    end
  end

  describe '#start with transport available' do
    it 'subscribes the outbound queue and routes delivered payloads' do
      outbound_queue = double('OutboundQueue')
      outbound_class = double('OutboundClass', new: outbound_queue)
      delivery_info = double('delivery_info', delivery_tag: 'tag-1')
      payload = Legion::JSON.dump({ id: 'frame-2', content: 'hello', content_type: :text, channel_id: :cli })

      stub_const('Legion::Gaia::Router::Transport', Module.new) unless defined?(Legion::Gaia::Router::Transport)
      stub_const('Legion::Gaia::Router::Transport::Queues', Module.new)
      stub_const('Legion::Gaia::Router::Transport::Queues::Outbound', outbound_class)
      allow(bridge).to receive(:transport_available?).and_return(true)
      allow(outbound_queue).to receive(:subscribe) do |manual_ack:, block:, &handler|
        expect(manual_ack).to be true
        expect(block).to be false
        handler.call(delivery_info, nil, payload)
        double('consumer', cancel: true)
      end
      allow(outbound_queue).to receive(:acknowledge)

      bridge.start

      expect(cli_adapter.last_output).to eq('hello')
      expect(outbound_queue).to have_received(:acknowledge).with('tag-1')
    end
  end
end
