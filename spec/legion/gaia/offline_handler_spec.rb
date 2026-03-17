# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::OfflineHandler do
  before { described_class.reset! }

  describe '.agent_online?' do
    it 'returns false for unknown worker' do
      expect(described_class.agent_online?('unknown')).to be false
    end

    it 'returns true after recording presence' do
      described_class.record_presence('worker-1')
      expect(described_class.agent_online?('worker-1')).to be true
    end
  end

  describe '.record_presence' do
    it 'stores presence for worker' do
      described_class.record_presence('w-1')
      expect(described_class.agent_online?('w-1')).to be true
    end
  end

  describe '.pending_count' do
    it 'returns 0 for no pending' do
      expect(described_class.pending_count('worker-1')).to eq(0)
    end
  end

  describe '.drain_pending' do
    it 'returns empty array for no pending' do
      expect(described_class.drain_pending('worker-1')).to eq([])
    end
  end

  describe '.handle_offline_delivery' do
    let(:channel_registry) { instance_double(Legion::Gaia::ChannelRegistry) }
    let(:input_frame) do
      Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :cli,
        auth_context: { identity: 'user-1' }
      )
    end

    before do
      allow(Legion::Gaia).to receive(:channel_registry).and_return(channel_registry)
      allow(channel_registry).to receive(:deliver).and_return({ delivered: true })
    end

    it 'queues the message and returns result' do
      result = described_class.handle_offline_delivery(input_frame, worker_id: 'w-1')
      expect(result[:queued]).to be true
      expect(result[:worker_id]).to eq('w-1')
    end

    it 'increments pending count' do
      described_class.handle_offline_delivery(input_frame, worker_id: 'w-1')
      expect(described_class.pending_count('w-1')).to eq(1)
    end

    it 'drains pending messages' do
      described_class.handle_offline_delivery(input_frame, worker_id: 'w-1')
      messages = described_class.drain_pending('w-1')
      expect(messages.size).to eq(1)
      expect(messages.first[:frame]).to eq(input_frame)
      expect(described_class.pending_count('w-1')).to eq(0)
    end
  end
end
