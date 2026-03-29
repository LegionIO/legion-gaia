# frozen_string_literal: true

RSpec.describe Legion::Gaia::Workflow::Checkpoint do
  subject(:cp) do
    described_class.new(state: :enriching, name: :quality_check, condition: ->(ctx) { ctx[:score].to_f >= 0.8 })
  end

  it 'stores state and name' do
    expect(cp.state).to eq(:enriching)
    expect(cp.name).to eq(:quality_check)
  end

  describe '#satisfied?' do
    it 'returns true when condition passes' do
      expect(cp.satisfied?(score: 0.9)).to be true
    end

    it 'returns false when condition fails' do
      expect(cp.satisfied?(score: 0.5)).to be false
    end

    it 'returns true when condition is nil (unconditional pass)' do
      unconditional = described_class.new(state: :pending, name: :noop, condition: nil)
      expect(unconditional.satisfied?).to be true
    end

    it 'defaults ctx to empty hash' do
      always_pass = described_class.new(state: :pending, name: :always, condition: ->(_ctx) { true })
      expect(always_pass.satisfied?).to be true
    end
  end

  it 'is a value object (Data.define)' do
    cp2 = described_class.new(state: :enriching, name: :quality_check, condition: cp.condition)
    expect(cp2).to eq(cp)
  end
end
