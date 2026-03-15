# frozen_string_literal: true

RSpec.describe Legion::Gaia::ChannelAdapter do
  subject(:adapter) { described_class.new(channel_id: :test, capabilities: %i[rich_text]) }

  describe '#initialize' do
    it 'sets channel_id and capabilities' do
      expect(adapter.channel_id).to eq(:test)
      expect(adapter.capabilities).to eq(%i[rich_text])
    end

    it 'starts in stopped state' do
      expect(adapter.started?).to be false
    end
  end

  describe '#start / #stop' do
    it 'toggles started state' do
      adapter.start
      expect(adapter.started?).to be true
      adapter.stop
      expect(adapter.started?).to be false
    end
  end

  describe '#supports?' do
    it 'returns true for supported capabilities' do
      expect(adapter.supports?(:rich_text)).to be true
    end

    it 'returns false for unsupported capabilities' do
      expect(adapter.supports?(:voice_response)).to be false
    end
  end

  describe 'abstract methods' do
    it 'raises NotImplementedError for translate_inbound' do
      expect { adapter.translate_inbound('input') }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for translate_outbound' do
      frame = Legion::Gaia::OutputFrame.new(content: 'x', channel_id: :test)
      expect { adapter.translate_outbound(frame) }.to raise_error(NotImplementedError)
    end

    it 'raises NotImplementedError for deliver' do
      frame = Legion::Gaia::OutputFrame.new(content: 'x', channel_id: :test)
      expect { adapter.deliver(frame) }.to raise_error(NotImplementedError)
    end
  end
end
