# frozen_string_literal: true

RSpec.describe Legion::Gaia::Channels::SlackAdapter do
  subject(:adapter) { described_class.new(signing_secret: 'test-secret', default_webhook: '/services/T/B/x') }

  let(:slack_event) do
    {
      'type' => 'message',
      'text' => 'hello bot',
      'user' => 'U12345',
      'channel' => 'C67890',
      'team' => 'T11111',
      'ts' => '1234567890.123456',
      'thread_ts' => nil
    }
  end

  describe '#initialize' do
    it 'sets channel_id to :slack' do
      expect(adapter.channel_id).to eq(:slack)
    end

    it 'has Slack capabilities' do
      expect(adapter.capabilities).to include(:rich_text, :threads, :reactions, :mentions)
    end

    it 'stores signing_secret' do
      expect(adapter.signing_secret).to eq('test-secret')
    end
  end

  describe '#translate_inbound' do
    it 'creates an InputFrame from Slack event' do
      frame = adapter.translate_inbound(slack_event)
      expect(frame).to be_a(Legion::Gaia::InputFrame)
      expect(frame.content).to eq('hello bot')
      expect(frame.channel_id).to eq(:slack)
      expect(frame.metadata[:source_type]).to eq(:human_direct)
    end

    it 'extracts auth context' do
      frame = adapter.translate_inbound(slack_event)
      expect(frame.auth_context[:user_id]).to eq('U12345')
      expect(frame.auth_context[:team_id]).to eq('T11111')
      expect(frame.auth_context[:identity]).to eq('U12345')
    end

    it 'extracts Slack metadata' do
      frame = adapter.translate_inbound(slack_event)
      expect(frame.metadata[:slack_channel]).to eq('C67890')
      expect(frame.metadata[:slack_ts]).to eq('1234567890.123456')
    end

    it 'strips bot mentions' do
      event = slack_event.merge('text' => '<@U999BOT> hello bot')
      frame = adapter.translate_inbound(event)
      expect(frame.content).to eq('hello bot')
    end

    it 'returns nil for non-hash input' do
      expect(adapter.translate_inbound('not a hash')).to be_nil
      expect(adapter.translate_inbound(nil)).to be_nil
    end
  end

  describe '#translate_outbound' do
    it 'converts OutputFrame to Slack message hash' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :slack)
      result = adapter.translate_outbound(frame)
      expect(result[:text]).to eq('hello')
    end

    it 'includes thread_ts when present in metadata' do
      frame = Legion::Gaia::OutputFrame.new(
        content: 'reply',
        channel_id: :slack,
        metadata: { slack_thread_ts: '123.456', slack_channel: 'C67890' }
      )
      result = adapter.translate_outbound(frame)
      expect(result[:thread_ts]).to eq('123.456')
      expect(result[:channel]).to eq('C67890')
    end
  end

  describe '#deliver' do
    it 'returns error when lex-slack not loaded' do
      result = adapter.deliver({ text: 'hello' })
      expect(result[:error]).to eq(:slack_runner_not_available)
    end

    context 'with bot_token and no webhook' do
      subject(:adapter) { described_class.new(bot_token: 'xoxb-test') }

      it 'returns not_implemented for API delivery' do
        result = adapter.deliver({ text: 'hello' })
        expect(result[:error]).to eq(:not_implemented)
      end
    end
  end

  describe '#verify_request' do
    it 'returns error when no signing secret' do
      adapter_no_secret = described_class.new
      result = adapter_no_secret.verify_request(timestamp: '123', body: 'x', signature: 'v0=abc')
      expect(result[:error]).to eq(:no_signing_secret)
    end

    it 'delegates to SigningVerifier' do
      result = adapter.verify_request(
        timestamp: Time.now.to_i.to_s,
        body: 'test-body',
        signature: 'v0=wrong'
      )
      expect(result[:error]).to eq(:signature_mismatch)
    end
  end
end
