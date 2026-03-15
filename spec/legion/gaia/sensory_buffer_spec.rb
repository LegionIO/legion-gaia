# frozen_string_literal: true

RSpec.describe Legion::Gaia::SensoryBuffer do
  subject(:buffer) { described_class.new }

  describe '#push' do
    it 'adds a signal to the buffer' do
      buffer.push({ salience: 0.5 })
      expect(buffer.size).to eq(1)
    end

    it 'normalizes hash signals with defaults' do
      buffer.push({ value: 'test' })
      signals = buffer.drain
      expect(signals.first).to include(:received_at, :salience, :source_type)
    end

    it 'wraps non-hash signals' do
      buffer.push('raw_string')
      signals = buffer.drain
      expect(signals.first[:value]).to eq('raw_string')
    end

    it 'caps at MAX_BUFFER_SIZE' do
      (described_class::MAX_BUFFER_SIZE + 10).times { |i| buffer.push({ i: i }) }
      expect(buffer.size).to eq(described_class::MAX_BUFFER_SIZE)
    end
  end

  describe '#drain' do
    it 'returns all signals and clears the buffer' do
      buffer.push({ a: 1 })
      buffer.push({ b: 2 })

      signals = buffer.drain
      expect(signals.size).to eq(2)
      expect(buffer.size).to eq(0)
    end

    it 'returns empty array when buffer is empty' do
      expect(buffer.drain).to eq([])
    end
  end

  describe '#empty?' do
    it 'returns true when empty' do
      expect(buffer.empty?).to be true
    end

    it 'returns false when signals present' do
      buffer.push({ x: 1 })
      expect(buffer.empty?).to be false
    end
  end
end
