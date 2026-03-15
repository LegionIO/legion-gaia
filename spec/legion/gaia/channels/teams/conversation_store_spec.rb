# frozen_string_literal: true

RSpec.describe Legion::Gaia::Channels::Teams::ConversationStore do
  subject(:store) { described_class.new }

  describe '#store and #lookup' do
    it 'stores and retrieves a conversation reference' do
      store.store(conversation_id: 'conv-1', service_url: 'https://smba.trafficmanager.net/teams/')
      ref = store.lookup('conv-1')
      expect(ref).to be_a(described_class::Reference)
      expect(ref.conversation_id).to eq('conv-1')
      expect(ref.service_url).to eq('https://smba.trafficmanager.net/teams/')
    end

    it 'stores tenant_id and bot_id' do
      store.store(conversation_id: 'conv-2', service_url: 'https://example.com',
                  tenant_id: 'tid-1', bot_id: 'bot-1', activity_id: 'act-1')
      ref = store.lookup('conv-2')
      expect(ref.tenant_id).to eq('tid-1')
      expect(ref.bot_id).to eq('bot-1')
      expect(ref.last_activity_id).to eq('act-1')
    end

    it 'returns nil for unknown conversation' do
      expect(store.lookup('nonexistent')).to be_nil
    end

    it 'overwrites existing reference on re-store' do
      store.store(conversation_id: 'conv-1', service_url: 'https://old.example.com')
      store.store(conversation_id: 'conv-1', service_url: 'https://new.example.com')
      expect(store.lookup('conv-1').service_url).to eq('https://new.example.com')
    end
  end

  describe '#store_from_activity' do
    let(:activity) do
      {
        'id' => 'act-123',
        'serviceUrl' => 'https://smba.trafficmanager.net/teams/',
        'conversation' => { 'id' => 'conv-abc', 'tenantId' => 'tid-xyz' },
        'recipient' => { 'id' => 'bot-id-1' }
      }
    end

    it 'extracts and stores reference from activity' do
      store.store_from_activity(activity)
      ref = store.lookup('conv-abc')
      expect(ref.service_url).to eq('https://smba.trafficmanager.net/teams/')
      expect(ref.tenant_id).to eq('tid-xyz')
      expect(ref.bot_id).to eq('bot-id-1')
      expect(ref.last_activity_id).to eq('act-123')
    end
  end

  describe '#remove' do
    it 'removes a stored reference' do
      store.store(conversation_id: 'conv-1', service_url: 'https://example.com')
      store.remove('conv-1')
      expect(store.lookup('conv-1')).to be_nil
    end
  end

  describe '#conversations' do
    it 'returns all stored conversation IDs' do
      store.store(conversation_id: 'a', service_url: 'https://a.com')
      store.store(conversation_id: 'b', service_url: 'https://b.com')
      expect(store.conversations).to contain_exactly('a', 'b')
    end
  end

  describe '#size' do
    it 'returns count of stored references' do
      expect(store.size).to eq(0)
      store.store(conversation_id: 'x', service_url: 'https://x.com')
      expect(store.size).to eq(1)
    end
  end

  describe '#clear' do
    it 'removes all references' do
      store.store(conversation_id: 'a', service_url: 'https://a.com')
      store.store(conversation_id: 'b', service_url: 'https://b.com')
      store.clear
      expect(store.size).to eq(0)
    end
  end

  describe 'Reference' do
    it 'is a Data.define value object' do
      ref = described_class::Reference.new(conversation_id: 'c1', service_url: 'https://test.com')
      expect(ref).to be_frozen
      expect(ref.conversation_id).to eq('c1')
      expect(ref.updated_at).to be_a(Time)
    end
  end
end
