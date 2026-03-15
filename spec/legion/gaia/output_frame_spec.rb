# frozen_string_literal: true

RSpec.describe Legion::Gaia::OutputFrame do
  describe '.new' do
    it 'creates with required fields only' do
      frame = described_class.new(content: 'response', channel_id: :cli)
      expect(frame.content).to eq('response')
      expect(frame.channel_id).to eq(:cli)
    end

    it 'generates a UUID id' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.id).to match(/\A[0-9a-f-]{36}\z/)
    end

    it 'defaults in_reply_to to nil' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame.in_reply_to).to be_nil
    end

    it 'is frozen (immutable)' do
      frame = described_class.new(content: 'test', channel_id: :cli)
      expect(frame).to be_frozen
    end
  end

  describe '#suggest_richer_channel?' do
    it 'returns true when hint set' do
      frame = described_class.new(
        content: 'long',
        channel_id: :teams,
        channel_hints: { suggest_channel_switch: true }
      )
      expect(frame.suggest_richer_channel?).to be true
    end

    it 'returns false by default' do
      frame = described_class.new(content: 'short', channel_id: :cli)
      expect(frame.suggest_richer_channel?).to be false
    end
  end

  describe '#truncated?' do
    it 'returns true when hint set' do
      frame = described_class.new(content: 'x', channel_id: :teams, channel_hints: { truncated: true })
      expect(frame.truncated?).to be true
    end

    it 'returns false by default' do
      frame = described_class.new(content: 'x', channel_id: :cli)
      expect(frame.truncated?).to be false
    end
  end
end
