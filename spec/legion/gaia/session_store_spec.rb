# frozen_string_literal: true

RSpec.describe Legion::Gaia::SessionStore do
  subject(:store) { described_class.new(ttl: 3600) }

  describe '#find_or_create' do
    it 'creates a new session for a new identity' do
      session = store.find_or_create(identity: 'user@example.com')
      expect(session.identity).to eq('user@example.com')
      expect(session.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'returns existing session for known identity' do
      first = store.find_or_create(identity: 'user@example.com')
      second = store.find_or_create(identity: 'user@example.com')
      expect(second.id).to eq(first.id)
    end

    it 'creates separate sessions for different identities' do
      a = store.find_or_create(identity: 'alice')
      b = store.find_or_create(identity: 'bob')
      expect(a.id).not_to eq(b.id)
    end
  end

  describe '#touch' do
    it 'updates last_active_at' do
      session = store.find_or_create(identity: 'user')
      original = session.last_active_at
      sleep(0.01)
      updated = store.touch(session.id, channel_id: :cli)
      expect(updated.last_active_at).to be > original
    end

    it 'tracks channel history' do
      session = store.find_or_create(identity: 'user')
      store.touch(session.id, channel_id: :cli)
      store.touch(session.id, channel_id: :teams)
      updated = store.get(session.id)
      expect(updated.channel_history).to include(:cli, :teams)
    end

    it 'returns nil for unknown session' do
      expect(store.touch('nonexistent')).to be_nil
    end
  end

  describe '#get' do
    it 'retrieves a session by id' do
      session = store.find_or_create(identity: 'user')
      expect(store.get(session.id)).to eq(session)
    end
  end

  describe '#remove' do
    it 'removes a session' do
      session = store.find_or_create(identity: 'user')
      store.remove(session.id)
      expect(store.get(session.id)).to be_nil
      expect(store.size).to eq(0)
    end
  end

  describe '#size' do
    it 'returns session count' do
      expect(store.size).to eq(0)
      store.find_or_create(identity: 'a')
      store.find_or_create(identity: 'b')
      expect(store.size).to eq(2)
    end
  end

  describe '#prune_expired' do
    it 'removes expired sessions' do
      expired_store = described_class.new(ttl: 0)
      expired_store.find_or_create(identity: 'old')
      sleep(0.01)
      pruned = expired_store.prune_expired
      expect(pruned).to eq(1)
      expect(expired_store.size).to eq(0)
    end
  end
end
