# frozen_string_literal: true

RSpec.describe Legion::Gaia::Channels::TeamsAdapter do
  subject(:adapter) { described_class.new(app_id: 'test-app-id') }

  let(:base_activity) do
    {
      'id' => 'activity-1',
      'type' => 'message',
      'text' => 'hello bot',
      'serviceUrl' => 'https://smba.trafficmanager.net/teams/',
      'from' => { 'id' => 'user-1', 'name' => 'Alice', 'aadObjectId' => 'oid-1' },
      'recipient' => { 'id' => 'bot-1', 'name' => 'MyBot' },
      'conversation' => { 'id' => 'conv-1', 'tenantId' => 'tid-1' },
      'channelData' => { 'tenant' => { 'id' => 'tid-1' }, 'clientInfo' => { 'platform' => 'Windows' } },
      'entities' => []
    }
  end

  describe '#initialize' do
    it 'sets channel_id to :teams' do
      expect(adapter.channel_id).to eq(:teams)
    end

    it 'has Teams capabilities' do
      expect(adapter.capabilities).to include(:adaptive_cards, :proactive_messaging, :mobile, :desktop)
    end

    it 'stores app_id' do
      expect(adapter.app_id).to eq('test-app-id')
    end

    it 'creates a conversation store' do
      expect(adapter.conversation_store).to be_a(Legion::Gaia::Channels::Teams::ConversationStore)
    end
  end

  describe '#translate_inbound' do
    it 'creates an InputFrame from activity' do
      frame = adapter.translate_inbound(base_activity)
      expect(frame).to be_a(Legion::Gaia::InputFrame)
      expect(frame.content).to eq('hello bot')
      expect(frame.channel_id).to eq(:teams)
      expect(frame.metadata[:source_type]).to eq(:human_direct)
    end

    it 'extracts auth context' do
      frame = adapter.translate_inbound(base_activity)
      expect(frame.auth_context[:aad_object_id]).to eq('oid-1')
      expect(frame.auth_context[:user_id]).to eq('user-1')
      expect(frame.auth_context[:user_name]).to eq('Alice')
      expect(frame.auth_context[:tenant_id]).to eq('tid-1')
    end

    it 'stores conversation reference' do
      adapter.translate_inbound(base_activity)
      ref = adapter.conversation_store.lookup('conv-1')
      expect(ref).not_to be_nil
      expect(ref.service_url).to eq('https://smba.trafficmanager.net/teams/')
    end

    it 'stores activity metadata' do
      frame = adapter.translate_inbound(base_activity)
      expect(frame.metadata[:conversation_id]).to eq('conv-1')
      expect(frame.metadata[:activity_id]).to eq('activity-1')
      expect(frame.metadata[:activity_type]).to eq('message')
    end

    it 'strips bot mention from text' do
      activity = base_activity.merge(
        'text' => '<at>MyBot</at> hello bot',
        'entities' => [
          { 'type' => 'mention', 'text' => '<at>MyBot</at>',
            'mentioned' => { 'id' => 'bot-1', 'name' => 'MyBot' } }
        ]
      )
      frame = adapter.translate_inbound(activity)
      expect(frame.content).to eq('hello bot')
    end

    it 'detects mobile device context' do
      activity = base_activity.dup
      activity['channelData'] = { 'tenant' => { 'id' => 'tid-1' },
                                  'clientInfo' => { 'platform' => 'iOS' } }
      frame = adapter.translate_inbound(activity)
      expect(frame.device_context[:platform]).to eq(:ios)
      expect(frame.channel_capabilities).to include(:mobile)
      expect(frame.channel_capabilities).not_to include(:desktop)
    end

    it 'returns nil for non-hash input' do
      expect(adapter.translate_inbound('not a hash')).to be_nil
      expect(adapter.translate_inbound(nil)).to be_nil
    end
  end

  describe '#translate_outbound' do
    it 'converts text OutputFrame to text hash' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :teams)
      result = adapter.translate_outbound(frame)
      expect(result).to eq({ type: 'text', text: 'hello' })
    end

    it 'converts adaptive_card OutputFrame to card hash' do
      card_content = { 'type' => 'AdaptiveCard', 'body' => [] }
      frame = Legion::Gaia::OutputFrame.new(content: card_content, channel_id: :teams,
                                            content_type: :adaptive_card)
      result = adapter.translate_outbound(frame)
      expect(result[:type]).to eq('adaptive_card')
      expect(result[:card]).to eq(card_content)
    end
  end

  describe '#deliver' do
    it 'returns error when no conversation reference exists' do
      result = adapter.deliver('hello', conversation_id: 'nonexistent')
      expect(result[:error]).to eq(:no_conversation_reference)
    end

    it 'returns error when conversation_id is nil' do
      result = adapter.deliver('hello')
      expect(result[:error]).to eq(:no_conversation_reference)
    end

    it 'returns error when bot runner is not available' do
      adapter.translate_inbound(base_activity)
      result = adapter.deliver({ type: 'text', text: 'hello' }, conversation_id: 'conv-1')
      expect(result[:error]).to eq(:bot_runner_not_available)
    end
  end

  describe '#validate_inbound' do
    it 'validates a token against app_id' do
      result = adapter.validate_inbound(nil)
      expect(result[:error]).to eq(:missing_token)
    end

    it 'returns error when no app_id configured' do
      adapter_no_id = described_class.new
      result = adapter_no_id.validate_inbound('some-token')
      expect(result[:error]).to eq(:no_app_id)
    end
  end
end
