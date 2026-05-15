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
end
