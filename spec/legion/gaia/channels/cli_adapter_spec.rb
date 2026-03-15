# frozen_string_literal: true

RSpec.describe Legion::Gaia::Channels::CliAdapter do
  subject(:adapter) { described_class.new }

  describe '#initialize' do
    it 'sets channel_id to :cli' do
      expect(adapter.channel_id).to eq(:cli)
    end

    it 'has desktop capabilities' do
      expect(adapter.capabilities).to include(:rich_text, :inline_code, :syntax_highlighting)
    end
  end

  describe '#translate_inbound' do
    it 'creates an InputFrame from a string' do
      frame = adapter.translate_inbound('hello world')
      expect(frame).to be_a(Legion::Gaia::InputFrame)
      expect(frame.content).to eq('hello world')
      expect(frame.channel_id).to eq(:cli)
      expect(frame.metadata[:source_type]).to eq(:human_direct)
      expect(frame.metadata[:salience]).to eq(0.9)
    end

    it 'sets device context to desktop keyboard' do
      frame = adapter.translate_inbound('test')
      expect(frame.device_context[:platform]).to eq(:desktop)
      expect(frame.device_context[:input_method]).to eq(:keyboard)
    end
  end

  describe '#translate_outbound' do
    it 'extracts content string from OutputFrame' do
      frame = Legion::Gaia::OutputFrame.new(content: 'response text', channel_id: :cli)
      result = adapter.translate_outbound(frame)
      expect(result).to eq('response text')
    end
  end

  describe '#deliver' do
    it 'buffers the rendered content' do
      adapter.deliver('first')
      adapter.deliver('second')
      expect(adapter.output_buffer_size).to eq(2)
      expect(adapter.last_output).to eq('second')
    end
  end

  describe '#drain_output' do
    it 'returns all buffered output and clears' do
      adapter.deliver('a')
      adapter.deliver('b')
      output = adapter.drain_output
      expect(output).to eq(%w[a b])
      expect(adapter.output_buffer_size).to eq(0)
    end
  end
end
