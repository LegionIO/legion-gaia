# frozen_string_literal: true

module Legion
  module Extensions
    module Actors
      class Every # rubocop:disable Lint/EmptyClass
      end
    end
  end
end

$LOADED_FEATURES << 'legion/extensions/actors/every'

require 'legion/gaia/actors/heartbeat'

RSpec.describe Legion::Gaia::Actors::Heartbeat do
  subject(:actor) { described_class.new }

  describe '#runner_class' do
    it 'returns Legion::Gaia' do
      expect(actor.runner_class).to eq(Legion::Gaia)
    end
  end

  describe '#runner_function' do
    it 'returns heartbeat' do
      expect(actor.runner_function).to eq('heartbeat')
    end
  end

  describe '#time' do
    it 'returns 1 by default' do
      allow(Legion::Gaia).to receive(:settings).and_return({ heartbeat_interval: 1 })
      expect(actor.time).to eq(1)
    end

    it 'reads from settings' do
      allow(Legion::Gaia).to receive(:settings).and_return({ heartbeat_interval: 5 })
      expect(actor.time).to eq(5)
    end

    it 'defaults to 1 when settings nil' do
      allow(Legion::Gaia).to receive(:settings).and_return(nil)
      expect(actor.time).to eq(1)
    end
  end

  describe '#run_now?' do
    it 'returns true' do
      expect(actor.run_now?).to be true
    end
  end

  describe '#use_runner?' do
    it 'returns false' do
      expect(actor.use_runner?).to be false
    end
  end

  describe '#check_subtask?' do
    it 'returns false' do
      expect(actor.check_subtask?).to be false
    end
  end

  describe '#generate_task?' do
    it 'returns false' do
      expect(actor.generate_task?).to be false
    end
  end
end
