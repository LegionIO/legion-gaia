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

  describe 'delivery after relationship revocation' do
    let(:gate) { Legion::Gaia::NotificationGate.new }
    subject(:router) { described_class.new(channel_registry: channel_registry, notification_gate: gate) }

    before { Legion::Gaia::BondRegistry.reset! }
    after { Legion::Gaia::BondRegistry.reset! }

    it 'discards a terminated owner delayed frame without losing another owner response' do
      allow(gate.schedule_evaluator).to receive(:quiet?).and_return(true)
      alice = Legion::Gaia::OutputFrame.new(content: 'alice private', channel_id: :cli, metadata: { identity: 'alice' })
      bob = Legion::Gaia::OutputFrame.new(content: 'bob private', channel_id: :cli, metadata: { identity: 'bob' })
      expect(router.route(alice)[:reason]).to eq(:delayed)
      expect(router.route(bob)[:reason]).to eq(:delayed)
      Legion::Gaia::BondRegistry.set_bond_state('alice', :terminated)
      allow(gate.schedule_evaluator).to receive(:quiet?).and_return(false)
      router.process_delayed
      expect(cli_adapter.drain_output).to eq(['bob private'])
      expect(gate.pending_count).to eq(0)
      expect(router.route(alice)).to eq({ delivered: false, reason: :bond_blocked })
    end

    it 'rechecks the owner after rendering before performing delivery' do
      renderer = double('renderer')
      router = described_class.new(channel_registry: channel_registry, renderer: renderer)
      frame = Legion::Gaia::OutputFrame.new(content: 'private', channel_id: :cli, metadata: { identity: 'alice' })
      allow(renderer).to receive(:render) do |output|
        Legion::Gaia::BondRegistry.set_bond_state('alice', :revoked)
        output
      end
      expect(router.route(frame)).to eq({ delivered: false, reason: :bond_blocked })
      expect(cli_adapter.drain_output).to be_empty
    end
  end
end
