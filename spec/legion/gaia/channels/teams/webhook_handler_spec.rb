# frozen_string_literal: true

require 'json'

RSpec.describe Legion::Gaia::Channels::Teams::WebhookHandler do
  let(:adapter) { Legion::Gaia::Channels::TeamsAdapter.new(app_id: 'test-app-id') }
  subject(:handler) { described_class.new(adapter) }

  let(:message_activity) do
    {
      'id' => 'act-1',
      'type' => 'message',
      'text' => 'hello',
      'serviceUrl' => 'https://smba.trafficmanager.net/teams/',
      'from' => { 'id' => 'user-1', 'name' => 'Alice', 'aadObjectId' => 'oid-1' },
      'recipient' => { 'id' => 'bot-1' },
      'conversation' => { 'id' => 'conv-1', 'tenantId' => 'tid-1' },
      'channelData' => { 'tenant' => { 'id' => 'tid-1' } },
      'entities' => []
    }
  end

  describe '#handle' do
    context 'with message activity' do
      it 'translates and returns success' do
        result = handler.handle(request_body: message_activity)
        expect(result[:status]).to eq(200)
        expect(result[:type]).to eq(:message_ingested)
        expect(result[:frame_id]).to be_a(String)
      end

      it 'parses JSON string body' do
        json_body = JSON.dump(message_activity)
        result = handler.handle(request_body: json_body)
        expect(result[:status]).to eq(200)
        expect(result[:type]).to eq(:message_ingested)
      end
    end

    context 'with conversationUpdate activity' do
      let(:update_activity) do
        message_activity.merge(
          'type' => 'conversationUpdate',
          'membersAdded' => [{ 'id' => 'user-2' }],
          'membersRemoved' => []
        )
      end

      it 'returns conversation update response' do
        result = handler.handle(request_body: update_activity)
        expect(result[:status]).to eq(200)
        expect(result[:type]).to eq(:conversation_update)
        expect(result[:members_added]).to eq(1)
        expect(result[:members_removed]).to eq(0)
      end

      it 'stores conversation reference' do
        handler.handle(request_body: update_activity)
        ref = adapter.conversation_store.lookup('conv-1')
        expect(ref).not_to be_nil
      end
    end

    context 'with invoke activity' do
      let(:invoke_activity) do
        message_activity.merge('type' => 'invoke', 'name' => 'adaptiveCard/action')
      end

      it 'returns invoke response' do
        result = handler.handle(request_body: invoke_activity)
        expect(result[:status]).to eq(200)
        expect(result[:type]).to eq(:invoke)
        expect(result[:activity_type]).to eq('adaptiveCard/action')
      end
    end

    context 'with unknown activity type' do
      let(:unknown_activity) { message_activity.merge('type' => 'typing') }

      it 'returns ignored response' do
        result = handler.handle(request_body: unknown_activity)
        expect(result[:status]).to eq(200)
        expect(result[:type]).to eq(:ignored)
      end
    end

    context 'with invalid payload' do
      it 'returns error for unparseable body' do
        result = handler.handle(request_body: 'not json at all {{{')
        expect(result[:status]).to eq(401)
        expect(result[:type]).to eq(:invalid_payload)
      end
    end

    context 'with auth validation' do
      it 'rejects invalid token when auth_header provided' do
        result = handler.handle(request_body: message_activity, auth_header: 'Bearer invalid-token')
        expect(result[:status]).to eq(401)
        expect(result[:type]).to eq(:auth_failed)
      end

      it 'skips auth when no auth_header provided' do
        result = handler.handle(request_body: message_activity)
        expect(result[:status]).to eq(200)
      end
    end
  end
end
