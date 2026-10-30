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

  describe '#store_user_profile and #lookup_user_profile' do
    it 'stores and retrieves a user profile' do
      store.store_user_profile(user_id: 'u-1', service_url: 'https://smba.trafficmanager.net/teams/',
                               tenant_id: 'tid-1')
      profile = store.lookup_user_profile('u-1')
      expect(profile).to be_a(described_class::UserProfile)
      expect(profile.user_id).to eq('u-1')
      expect(profile.service_url).to eq('https://smba.trafficmanager.net/teams/')
      expect(profile.tenant_id).to eq('tid-1')
    end

    it 'returns nil for unknown user' do
      expect(store.lookup_user_profile('unknown')).to be_nil
    end

    it 'ignores store when user_id is nil' do
      store.store_user_profile(user_id: nil, service_url: 'https://example.com')
      expect(store.lookup_user_profile(nil)).to be_nil
    end

    it 'ignores store when service_url is nil' do
      store.store_user_profile(user_id: 'u-1', service_url: nil)
      expect(store.lookup_user_profile('u-1')).to be_nil
    end
  end

  describe '#conversations_for_user' do
    it 'returns only the exact user personal conversation, not a tenant peer or shared channel' do
      store.store(conversation_id: 'alice-dm', service_url: 'https://smba.net/', tenant_id: 'tenant',
                  user_id: 'alice', conversation_type: 'personal')
      store.store(conversation_id: 'bob-dm', service_url: 'https://smba.net/', tenant_id: 'tenant',
                  user_id: 'bob', conversation_type: 'personal')
      store.store(conversation_id: 'shared', service_url: 'https://smba.net/', tenant_id: 'tenant',
                  user_id: 'alice', conversation_type: 'channel')
      expect(store.conversations_for_user('alice').map(&:conversation_id)).to eq(['alice-dm'])
      expect(store.conversations_for_user('bob').map(&:conversation_id)).to eq(['bob-dm'])
      expect(store.conversations_for_user('unknown')).to be_empty
    end

    it 'requires a tenant when native user or conversation IDs overlap' do
      %w[tenant-a tenant-b].each do |tenant|
        store.store(conversation_id: 'dm', service_url: "https://#{tenant}.example/", tenant_id: tenant,
                    user_id: 'alice', conversation_type: 'personal')
        store.store_user_profile(user_id: 'alice', service_url: "https://#{tenant}.example/", tenant_id: tenant)
      end
      expect(store.conversations_for_user('alice')).to be_empty
      expect(store.lookup('dm')).to be_nil
      expect(store.lookup_user_profile('alice')).to be_nil
      expect(store.conversations_for_user('alice', tenant_id: 'tenant-b').map(&:tenant_id)).to eq(['tenant-b'])
      expect(store.lookup('dm', tenant_id: 'tenant-a').service_url).to eq('https://tenant-a.example/')
      expect(store.lookup_user_profile('alice', tenant_id: 'tenant-b').service_url).to eq('https://tenant-b.example/')
    end
  end

  describe '#store_from_activity' do
    let(:activity) do
      {
        'id' => 'act-123',
        'serviceUrl' => 'https://smba.trafficmanager.net/teams/',
        'from' => { 'id' => 'user-1', 'name' => 'Alice' },
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

    it 'stores user profile from activity' do
      store.store_from_activity(activity)
      profile = store.lookup_user_profile('user-1')
      expect(profile).not_to be_nil
      expect(profile.service_url).to eq('https://smba.trafficmanager.net/teams/')
      expect(profile.tenant_id).to eq('tid-xyz')
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
    it 'removes all references and user profiles' do
      store.store(conversation_id: 'a', service_url: 'https://a.com')
      store.store(conversation_id: 'b', service_url: 'https://b.com')
      store.store_user_profile(user_id: 'u-1', service_url: 'https://a.com', tenant_id: 'tid-1')
      store.clear
      expect(store.size).to eq(0)
      expect(store.lookup_user_profile('u-1')).to be_nil
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

  describe 'UserProfile' do
    it 'is a Data.define value object' do
      profile = described_class::UserProfile.new(user_id: 'u1', service_url: 'https://smba.net/')
      expect(profile).to be_frozen
      expect(profile.user_id).to eq('u1')
      expect(profile.updated_at).to be_a(Time)
    end

    it 'allows nil tenant_id' do
      profile = described_class::UserProfile.new(user_id: 'u1', service_url: 'https://smba.net/')
      expect(profile.tenant_id).to be_nil
    end
  end
end
