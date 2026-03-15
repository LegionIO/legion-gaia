# frozen_string_literal: true

RSpec.describe Legion::Gaia::ChannelAwareRenderer do
  subject(:renderer) { described_class.new }

  describe '#render' do
    it 'passes through CLI output unchanged (no max_length)' do
      frame = Legion::Gaia::OutputFrame.new(content: 'x' * 10_000, channel_id: :cli)
      result = renderer.render(frame)
      expect(result.content.length).to eq(10_000)
      expect(result.truncated?).to be false
    end

    it 'truncates Teams mobile output exceeding max_length' do
      long_content = 'x' * 1000
      frame = Legion::Gaia::OutputFrame.new(
        content: long_content,
        channel_id: :teams,
        metadata: { device_context: :mobile }
      )
      result = renderer.render(frame)
      expect(result.content.length).to eq(500)
      expect(result.truncated?).to be true
      expect(result.channel_hints[:original_length]).to eq(1000)
    end

    it 'does not truncate short Teams mobile output' do
      frame = Legion::Gaia::OutputFrame.new(
        content: 'short',
        channel_id: :teams,
        metadata: { device_context: :mobile }
      )
      result = renderer.render(frame)
      expect(result.content).to eq('short')
      expect(result.truncated?).to be false
    end

    it 'suggests channel switch for long mobile content' do
      long_content = 'x' * 1000
      frame = Legion::Gaia::OutputFrame.new(
        content: long_content,
        channel_id: :teams,
        metadata: { device_context: :mobile }
      )
      result = renderer.render(frame)
      expect(result.suggest_richer_channel?).to be true
    end

    it 'does not suggest channel switch for CLI' do
      long_content = 'x' * 10_000
      frame = Legion::Gaia::OutputFrame.new(content: long_content, channel_id: :cli)
      result = renderer.render(frame)
      expect(result.suggest_richer_channel?).to be false
    end

    it 'preserves all non-content fields' do
      frame = Legion::Gaia::OutputFrame.new(
        content: 'x' * 1000,
        channel_id: :teams,
        in_reply_to: 'abc',
        session_continuity_id: 'sess-1',
        metadata: { device_context: :mobile, custom: true }
      )
      result = renderer.render(frame)
      expect(result.id).to eq(frame.id)
      expect(result.in_reply_to).to eq('abc')
      expect(result.session_continuity_id).to eq('sess-1')
      expect(result.metadata[:custom]).to be true
    end
  end
end
