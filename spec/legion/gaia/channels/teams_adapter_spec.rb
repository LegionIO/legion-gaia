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

    it 'returns error when conversation_id is nil and no default configured' do
      result = adapter.deliver('hello')
      expect(result[:error]).to eq(:no_conversation_reference)
    end

    it 'returns error when bot runner is not available' do
      adapter.translate_inbound(base_activity)
      result = adapter.deliver({ type: 'text', text: 'hello' }, conversation_id: 'conv-1')
      expect(result[:error]).to eq(:bot_runner_not_available)
    end

    context 'with default_conversation_id configured (Fix 4)' do
      subject(:adapter_with_default) do
        described_class.new(app_id: 'test-app-id', default_conversation_id: 'conv-1')
      end

      before { adapter_with_default.translate_inbound(base_activity) }

      it 'uses default_conversation_id when no conversation_id passed' do
        result = adapter_with_default.deliver({ type: 'text', text: 'hello' })
        # Bot runner not available in test — but we reached it (past the reference check)
        expect(result[:error]).to eq(:bot_runner_not_available)
      end

      it 'explicit conversation_id overrides default' do
        result = adapter_with_default.deliver({ type: 'text', text: 'hello' }, conversation_id: 'nonexistent')
        expect(result[:error]).to eq(:no_conversation_reference)
      end
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

  describe '#create_proactive_conversation' do
    it 'returns error when no user profile (no service_url)' do
      result = adapter.create_proactive_conversation(user_id: 'unknown-user')
      expect(result[:error]).to eq(:no_service_url)
    end

    it 'returns error when bot runner not available' do
      adapter.translate_inbound(base_activity)
      result = adapter.create_proactive_conversation(user_id: 'user-1')
      expect(result[:error]).to eq(:bot_runner_not_available)
    end

    it 'uses provided tenant_id when no profile tenant exists' do
      # store profile without tenant
      adapter.conversation_store.store_user_profile(
        user_id: 'u-no-tenant',
        service_url: 'https://smba.trafficmanager.net/teams/'
      )
      result = adapter.create_proactive_conversation(user_id: 'u-no-tenant', tenant_id: 'tid-override')
      # bot runner not available in test context
      expect(result[:error]).to eq(:bot_runner_not_available)
    end
  end

  describe '#last_presence_status' do
    it 'is nil by default' do
      expect(adapter.last_presence_status).to be_nil
    end

    it 'stores presence status via update_presence_status' do
      adapter.update_presence_status(:Available)
      expect(adapter.last_presence_status).to eq(:Available)
    end

    it 'updates presence status' do
      adapter.update_presence_status(:Available)
      adapter.update_presence_status(:Busy)
      expect(adapter.last_presence_status).to eq(:Busy)
    end
  end

  describe '#deliver_proactive' do
    it 'returns error when no target_user in frame metadata' do
      frame = Legion::Gaia::OutputFrame.new(content: 'hi', channel_id: :teams)
      result = adapter.deliver_proactive(frame)
      expect(result[:error]).to eq(:no_target_user)
    end

    it 'returns error when no service_url for user' do
      frame = Legion::Gaia::OutputFrame.new(
        content: 'hi',
        channel_id: :teams,
        metadata: { proactive: true, target_user: 'unknown-user' }
      )
      result = adapter.deliver_proactive(frame)
      expect(result[:error]).to eq(:no_service_url)
    end

    it 'resolves from existing conversation when user has prior conversation' do
      adapter.translate_inbound(base_activity)
      frame = Legion::Gaia::OutputFrame.new(
        content: 'hi',
        channel_id: :teams,
        metadata: { proactive: true, target_user: 'user-1' }
      )
      # Bot runner not available — falls through to conversation lookup then delivery error
      result = adapter.deliver_proactive(frame)
      # conv-1 exists for tid-1, user-1 profile has tenant tid-1 so conv found
      expect(result[:error]).to eq(:bot_runner_not_available)
    end
  end
end
