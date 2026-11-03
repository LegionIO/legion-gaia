# frozen_string_literal: true

RSpec.describe Legion::Gaia::InputFrame do
  describe '.new' do
    it 'creates with required fields only' do
      frame = described_class.new(content: 'hello', channel_id: :cli)
      expect(frame.content).to eq('hello')
      expect(frame.channel_id).to eq(:cli)
    end

    it 'generates a UUID id' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'defaults content_type to :text' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.content_type).to eq(:text)
    end

    it 'defaults channel_capabilities to empty array' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.channel_capabilities).to eq([])
    end

    it 'sets received_at to current time' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.received_at).to be_a(Time)
    end

    it 'is frozen (immutable)' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame).to be_frozen
    end
  end

  describe '#text?' do
    it 'returns true for text content' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.text?).to be true
    end

    it 'returns false for non-text content' do
      frame = described_class.new(content: 'data', channel_id: :cli, content_type: :binary)
      expect(frame.text?).to be false
    end
  end

  describe '#human_direct?' do
    it 'returns true when source_type is human_direct' do
      frame = described_class.new(content: 'hi', channel_id: :cli, metadata: { source_type: :human_direct })
      expect(frame.human_direct?).to be true
    end

    it 'returns false otherwise' do
      frame = described_class.new(content: 'hi', channel_id: :cli)
      expect(frame.human_direct?).to be false
    end
  end

  describe '#salience' do
    it 'returns salience from metadata' do
      frame = described_class.new(content: 'urgent', channel_id: :cli, metadata: { salience: 0.9 })
      expect(frame.salience).to eq(0.9)
    end

    it 'defaults to 0.0' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.salience).to eq(0.0)
    end
  end

  describe '#to_signal' do
    it 'converts to a signal hash for the sensory buffer' do
      frame = described_class.new(
        content: 'hello',
        channel_id: :cli,
        metadata: { source_type: :human_direct, salience: 0.8 }
      )
      signal = frame.to_signal

      expect(signal[:value]).to eq('hello')
      expect(signal[:source_type]).to eq(:human_direct)
      expect(signal[:salience]).to eq(0.8)
      expect(signal[:channel_id]).to eq(:cli)
      expect(signal[:frame_id]).to eq(frame.id)
    end

    it 'includes principal_id in the signal hash' do
      frame = described_class.new(content: 'hello', channel_id: 'test', principal_id: 42)
      expect(frame.to_signal[:principal_id]).to eq(42)
    end

    it 'includes nil principal_id when not set' do
      frame = described_class.new(content: 'hello', channel_id: 'test')
      expect(frame.to_signal[:principal_id]).to be_nil
    end
  end

  describe 'principal_id' do
    it 'defaults to nil when not provided' do
      frame = described_class.new(content: 'hello', channel_id: 'test')
      expect(frame.principal_id).to be_nil
    end

    it 'accepts an explicit integer principal_id' do
      frame = described_class.new(content: 'hello', channel_id: 'test', principal_id: 42)
      expect(frame.principal_id).to eq(42)
    end
  end

  describe '#resolved_principal_id' do
    it 'returns explicit principal_id when set' do
      frame = described_class.new(content: 'hello', channel_id: 'test',
                                  principal_id: 99, auth_context: { principal_id: 7 })
      expect(frame.resolved_principal_id).to eq(99)
    end

    it 'falls back to auth_context[:principal_id] when principal_id is nil' do
      frame = described_class.new(content: 'hello', channel_id: 'test',
                                  auth_context: { principal_id: 7 })
      expect(frame.resolved_principal_id).to eq(7)
    end

    it 'returns nil when neither is set' do
      frame = described_class.new(content: 'hello', channel_id: 'test')
      expect(frame.resolved_principal_id).to be_nil
    end
  end

  describe '#authenticated_identity' do
    it 'prefers the authenticated principal over a channel alias' do
      frame = described_class.new(content: 'hello', channel_id: :teams, principal_id: 'principal-a',
                                  auth_context: { identity: 'alias', tenant_id: 'tenant', user_id: 'user' })
      expect(frame.authenticated_identity).to eq('principal-a')
    end

    it 'preserves the trusted identity supplied by native and CLI callers' do
      frame = described_class.new(content: 'hello', channel_id: :cli, auth_context: { identity: 'human-a' })
      expect(frame.authenticated_identity).to eq('human-a')
    end

    it 'isolates identical channel aliases in separate tenants' do
      frames = %w[tenant-a tenant-b].map do |tenant|
        described_class.new(content: 'hello', channel_id: :teams,
                            auth_context: { tenant_id: tenant, aad_object_id: 'user' })
      end
      expect(frames.map(&:authenticated_identity)).to eq(%w[teams:tenant-a:user teams:tenant-b:user])
    end

    it 'does not authenticate from unscoped aliases, names, or continuity' do
      frame = described_class.new(content: 'hello', channel_id: :teams, session_continuity_id: 'known-session',
                                  auth_context: { user_id: 'user', canonical_name: 'Alice' })
      expect(frame.authenticated_identity).to be_nil
    end
  end

  it 'retains authenticated ownership and real correlation in sensory signals' do
    frame = described_class.new(content: 'hello', channel_id: :cli, id: 'frame-a',
                                auth_context: { identity: 'human-a' }, session_continuity_id: 'session-a',
                                metadata: { conversation_id: 'conversation-a', exchange_id: 'exchange-a' })
    expect(frame.to_signal).to include(identity: 'human-a', frame_id: 'frame-a',
                                       conversation_id: 'conversation-a', exchange_id: 'exchange-a',
                                       session_continuity_id: 'session-a')
    anonymous = described_class.new(content: 'hello', channel_id: :cli)
    expect(anonymous.to_signal.values_at(:identity, :conversation_id, :exchange_id)).to eq([nil, nil, nil])
  end

  it 'carries only the authenticated forecast request into cognitive signal metadata' do
    prediction = { domain: 'work', description: 'finish task', expected_outcome: 'done', identity: 'victim' }
    frame = described_class.new(content: 'forecast', channel_id: :cli, auth_context: { identity: 'human-a' },
                                metadata: { prediction_request: prediction, private_secret: 'not cognitive input' })
    expect(frame.to_signal[:metadata]).to eq({ prediction_request: prediction.except(:identity) })
    expect(frame.with(auth_context: {}).to_signal[:metadata]).to be_empty
  end
end
