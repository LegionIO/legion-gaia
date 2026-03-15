# frozen_string_literal: true

RSpec.describe Legion::Gaia::OutputRouter do
  let(:channel_registry) { Legion::Gaia::ChannelRegistry.new }
  let(:cli_adapter) { Legion::Gaia::Channels::CliAdapter.new }

  subject(:router) { described_class.new(channel_registry: channel_registry) }

  before do
    cli_adapter.start
    channel_registry.register(cli_adapter)
  end

  describe '#route' do
    it 'delivers an output frame to the correct channel' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :cli)
      result = router.route(frame)
      expect(result[:delivered]).to be true
      expect(cli_adapter.last_output).to eq('hello')
    end

    it 'returns failure for unregistered channel' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :teams)
      result = router.route(frame)
      expect(result[:delivered]).to be false
    end
  end

  describe '#route with renderer' do
    let(:renderer) { Legion::Gaia::ChannelAwareRenderer.new }

    subject(:router) { described_class.new(channel_registry: channel_registry, renderer: renderer) }

    it 'renders before delivering' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :cli)
      result = router.route(frame)
      expect(result[:delivered]).to be true
    end
  end

  describe '#route_to' do
    it 'overrides channel_id on the frame' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :teams)
      result = router.route_to(frame, channel_id: :cli)
      expect(result[:delivered]).to be true
      expect(cli_adapter.last_output).to eq('hello')
    end
  end
end
