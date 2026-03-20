# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Proactive do
  let(:channel_registry) { instance_double(Legion::Gaia::ChannelRegistry) }
  let(:output_router) { instance_double(Legion::Gaia::OutputRouter) }
  let(:cli_adapter) { instance_double(Legion::Gaia::ChannelAdapter) }

  before do
    allow(Legion::Gaia).to receive(:channel_registry).and_return(channel_registry)
    allow(Legion::Gaia).to receive(:output_router).and_return(output_router)
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
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
      allow(channel_registry).to receive(:deliver).and_return({ delivered: true, channel_id: :cli })

      result = described_class.send_message(channel_id: :cli, content: 'hello')
      expect(result[:sent]).to be true
      expect(result[:channel]).to eq(:cli)
    end
  end

  describe '.send_to_user' do
    context 'with explicit channel_id' do
      it 'returns error when registry unavailable' do
        allow(Legion::Gaia).to receive(:channel_registry).and_return(nil)
        result = described_class.send_to_user(user_id: 'u1', content: 'hi', channel_id: :cli)
        expect(result[:error]).to include('channel registry not available')
      end

      it 'returns error when adapter not found' do
        allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(nil)
        result = described_class.send_to_user(user_id: 'u1', content: 'hi', channel_id: :cli)
        expect(result[:error]).to include('no adapter')
      end

      it 'uses deliver_proactive when adapter supports it' do
        proactive_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter)
        allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(proactive_adapter)
        allow(proactive_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(true)
        allow(proactive_adapter).to receive(:deliver_proactive).and_return({ ok: true })

        result = described_class.send_to_user(user_id: 'u1', content: 'hi', channel_id: :teams)
        expect(result[:sent]).to be true
        expect(result[:user_id]).to eq('u1')
      end

      it 'falls back to registry deliver when adapter lacks deliver_proactive' do
        allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
        allow(cli_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(false)
        allow(channel_registry).to receive(:deliver).and_return({ delivered: true })

        result = described_class.send_to_user(user_id: 'u1', content: 'hi', channel_id: :cli)
        expect(result[:sent]).to be true
      end

      it 'passes through error from deliver_proactive' do
        proactive_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter)
        allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(proactive_adapter)
        allow(proactive_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(true)
        allow(proactive_adapter).to receive(:deliver_proactive).and_return({ error: :no_service_url })

        result = described_class.send_to_user(user_id: 'u1', content: 'hi', channel_id: :teams)
        expect(result[:error]).to eq(:no_service_url)
      end
    end

    context 'without channel_id (try all channels)' do
      it 'returns error when no active channels' do
        allow(channel_registry).to receive(:active_channels).and_return([])
        result = described_class.send_to_user(user_id: 'u1', content: 'hi')
        expect(result[:error]).to eq('no active channels')
      end

      it 'delivers to all active channels and returns results hash' do
        allow(channel_registry).to receive(:active_channels).and_return([:cli])
        allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
        allow(cli_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(false)
        allow(channel_registry).to receive(:deliver).and_return({ delivered: true })

        result = described_class.send_to_user(user_id: 'u1', content: 'hi')
        expect(result[:sent]).to be true
        expect(result[:results]).to have_key(:cli)
      end
    end
  end

  describe '.send_notification' do
    it 'returns error when registry unavailable' do
      allow(Legion::Gaia).to receive(:channel_registry).and_return(nil)
      result = described_class.send_notification(content: 'alert')
      expect(result[:error]).to include('channel registry not available')
    end

    it 'returns error when output_router unavailable' do
      allow(Legion::Gaia).to receive(:output_router).and_return(nil)
      allow(channel_registry).to receive(:active_channels).and_return([])
      result = described_class.send_notification(content: 'alert')
      expect(result[:error]).to include('output router not available')
    end

    it 'routes through output_router respecting priority' do
      allow(channel_registry).to receive(:active_channels).and_return([:cli])
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
      allow(output_router).to receive(:route).and_return({ delivered: true })

      result = described_class.send_notification(content: 'urgent msg', priority: :urgent)
      expect(result[:cli]).to eq({ delivered: true })
    end

    it 'routes to specific channel when channel_id given' do
      allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(cli_adapter)
      allow(output_router).to receive(:route).and_return({ delivered: true })

      result = described_class.send_notification(content: 'msg', channel_id: :teams)
      expect(result[:teams]).to eq({ delivered: true })
    end

    it 'skips channels with no adapter' do
      allow(channel_registry).to receive(:active_channels).and_return(%i[cli teams])
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
      allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(nil)
      allow(output_router).to receive(:route).and_return({ delivered: true })

      result = described_class.send_notification(content: 'msg')
      expect(result).to have_key(:cli)
      expect(result).not_to have_key(:teams)
    end

    it 'passes priority in frame metadata' do
      allow(channel_registry).to receive(:active_channels).and_return([:cli])
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)

      captured_frame = nil
      allow(output_router).to receive(:route) { |f|
        captured_frame = f
        { delivered: true }
      }

      described_class.send_notification(content: 'critical msg', priority: :critical)
      expect(captured_frame.metadata[:priority]).to eq(:critical)
    end
  end

  describe '.start_conversation' do
    it 'returns error when registry unavailable' do
      allow(Legion::Gaia).to receive(:channel_registry).and_return(nil)
      result = described_class.start_conversation(channel_id: :teams, user_id: 'u1', content: 'hi')
      expect(result[:error]).to include('channel registry not available')
    end

    it 'returns error when adapter not found' do
      allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(nil)
      result = described_class.start_conversation(channel_id: :teams, user_id: 'u1', content: 'hi')
      expect(result[:error]).to include('no adapter')
    end

    it 'uses deliver_proactive when adapter supports it' do
      proactive_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter)
      allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(proactive_adapter)
      allow(proactive_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(true)
      allow(proactive_adapter).to receive(:deliver_proactive).and_return({ ok: true })

      result = described_class.start_conversation(channel_id: :teams, user_id: 'u1', content: 'hi')
      expect(result[:started]).to be true
      expect(result[:channel]).to eq(:teams)
      expect(result[:user_id]).to eq('u1')
    end

    it 'passes error through from deliver_proactive' do
      proactive_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter)
      allow(channel_registry).to receive(:adapter_for).with(:teams).and_return(proactive_adapter)
      allow(proactive_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(true)
      allow(proactive_adapter).to receive(:deliver_proactive).and_return({ error: :no_service_url })

      result = described_class.start_conversation(channel_id: :teams, user_id: 'u1', content: 'hi')
      expect(result[:error]).to eq(:no_service_url)
    end

    it 'falls back to registry deliver when adapter lacks deliver_proactive' do
      allow(channel_registry).to receive(:adapter_for).with(:cli).and_return(cli_adapter)
      allow(cli_adapter).to receive(:respond_to?).with(:deliver_proactive).and_return(false)
      allow(channel_registry).to receive(:deliver).and_return({ delivered: true })

      result = described_class.start_conversation(channel_id: :cli, user_id: 'u1', content: 'hi')
      expect(result[:started]).to be true
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
