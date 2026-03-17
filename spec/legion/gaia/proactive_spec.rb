# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Proactive do
  let(:channel_registry) { instance_double(Legion::Gaia::ChannelRegistry) }

  before do
    allow(Legion::Gaia).to receive(:channel_registry).and_return(channel_registry)
  end

  describe '.send_message' do
    it 'returns error when channel registry unavailable' do
      allow(Legion::Gaia).to receive(:channel_registry).and_return(nil)
      result = described_class.send_message(channel_id: :teams, content: 'hello')
      expect(result[:error]).to include('channel registry not available')
    end

    it 'returns error for unknown channel' do
      allow(channel_registry).to receive(:adapter_for).with(:unknown).and_return(nil)
      result = described_class.send_message(channel_id: :unknown, content: 'test')
      expect(result[:error]).to include('no adapter')
    end

    it 'delivers message through registry' do
      adapter = instance_double(Legion::Gaia::ChannelAdapter)
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(adapter)
      allow(channel_registry).to receive(:deliver).and_return({ delivered: true, channel_id: :cli })

      result = described_class.send_message(channel_id: :cli, content: 'hello')
      expect(result[:sent]).to be true
      expect(result[:channel]).to eq(:cli)
    end
  end

  describe '.broadcast' do
    it 'sends to all active channels' do
      allow(channel_registry).to receive(:active_channels).and_return([])
      result = described_class.broadcast(content: 'test')
      expect(result).to eq({})
    end

    it 'sends to specified channels' do
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(nil)
      result = described_class.broadcast(content: 'test', channels: [:cli])
      expect(result[:cli][:error]).to include('no adapter')
    end

    it 'returns error when registry unavailable' do
      allow(Legion::Gaia).to receive(:channel_registry).and_return(nil)
      result = described_class.broadcast(content: 'test')
      expect(result[:error]).to include('channel registry not available')
    end
  end
end
