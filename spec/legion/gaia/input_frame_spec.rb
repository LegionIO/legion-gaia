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
  end
end
