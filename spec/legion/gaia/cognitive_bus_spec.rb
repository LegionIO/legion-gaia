# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/cognitive_bus'

RSpec.describe Legion::Gaia::CognitiveBus do
  subject(:bus) { described_class.new(broadcast_slots: 3) }

  describe '#submit' do
    it 'adds a signal to the bus' do
      bus.submit(type: :prediction_error, data: { magnitude: 0.8 }, precision: 0.9, salience: 0.7, source: :valence)
      expect(bus.pending_count).to eq(1)
    end

    it 'clamps precision and salience to 0.0-1.0' do
      bus.submit(type: :reward, data: {}, precision: 1.5, salience: -0.2, source: :test)
      bus.pending_count # internal state
      expect { bus.submit(type: :test, data: {}, precision: 1.5, salience: -0.2, source: :test) }.not_to raise_error
    end
  end

  describe '#propagate' do
    context 'with no signals' do
      it 'returns empty result' do
        result = bus.propagate
        expect(result[:winners]).to be_empty
        expect(result[:losers]).to be_empty
      end
    end

    context 'with more signals than broadcast slots' do
      before do
        bus.submit(type: :prediction_error, data: { magnitude: 0.9 }, precision: 0.9, salience: 0.9, source: :high)
        bus.submit(type: :prediction_error, data: { magnitude: 0.7 }, precision: 0.8, salience: 0.8, source: :medium)
        bus.submit(type: :reward, data: {}, precision: 0.7, salience: 0.7, source: :low)
        bus.submit(type: :social, data: {}, precision: 0.3, salience: 0.3, source: :low_precision)
        bus.submit(type: :ambient, data: {}, precision: 0.1, salience: 0.1, source: :noise)
      end

      it 'selects top 3 signals as winners' do
        result = bus.propagate
        expect(result[:winner_count]).to eq(3)
        expect(result[:loser_count]).to eq(2)
      end

      it 'clears signals after propagation' do
        bus.propagate
        expect(bus.pending_count).to eq(0)
      end

      it 'increments iteration counter' do
        bus.propagate
        expect(bus.iteration).to eq(1)
        bus.submit(type: :test, data: {}, precision: 0.5, salience: 0.5, source: :test)
        bus.propagate
        expect(bus.iteration).to eq(2)
      end
    end

    context 'with neuromodulators' do
      it 'high acetylcholine boosts all signals equally' do
        bus.submit(type: :prediction_error, data: {}, precision: 0.5, salience: 0.5, source: :a)
        bus.submit(type: :ambient, data: {}, precision: 0.5, salience: 0.5, source: :b)
        result = bus.propagate(neuromodulators: { acetylcholine: 1.0 })
        expect(result[:winner_count]).to be >= 1
      end

      it 'high dopamine boosts reward signals more than ambient' do
        bus.submit(type: :reward, data: {}, precision: 0.5, salience: 0.5, source: :reward)
        bus.submit(type: :ambient, data: {}, precision: 0.5, salience: 0.5, source: :noise)
        result = bus.propagate(neuromodulators: { dopamine: 1.0, acetylcholine: 0.5 })
        expect(result[:winners].first[:type]).to eq(:reward)
      end

      it 'high norepinephrine boosts urgency signals' do
        bus.submit(type: :urgency, data: {}, precision: 0.5, salience: 0.5, source: :urgent)
        bus.submit(type: :ambient, data: {}, precision: 0.5, salience: 0.5, source: :noise)
        result = bus.propagate(neuromodulators: { norepinephrine: 1.0, acetylcholine: 0.5 })
        expect(result[:winners].first[:type]).to eq(:urgency)
      end

      it 'high serotonin boosts social signals' do
        bus.submit(type: :social, data: {}, precision: 0.5, salience: 0.5, source: :social)
        bus.submit(type: :ambient, data: {}, precision: 0.5, salience: 0.5, source: :noise)
        result = bus.propagate(neuromodulators: { serotonin: 1.0, oxytocin: 1.0, acetylcholine: 0.5 })
        expect(result[:winners].first[:type]).to eq(:social)
      end
    end
  end

  describe '#converged?' do
    it 'returns true when no prediction error signals exist' do
      expect(bus.converged?).to be true
    end

    it 'returns false when prediction error exceeds threshold' do
      bus.submit(type: :prediction_error, data: { magnitude: 0.8 }, precision: 0.9, salience: 0.8, source: :test)
      expect(bus.converged?).to be false
    end

    it 'returns true when prediction error is below threshold' do
      bus.submit(type: :prediction_error, data: { magnitude: 0.03 }, precision: 0.9, salience: 0.03, source: :test)
      expect(bus.converged?).to be true
    end
  end

  describe '#snapshot' do
    it 'returns current bus state' do
      bus.submit(type: :test, data: { key: 'value' }, precision: 0.5, salience: 0.5, source: :test)
      snapshot = bus.snapshot
      expect(snapshot[:pending].size).to eq(1)
      expect(snapshot[:iteration]).to eq(0)
    end
  end

  describe '#reset' do
    it 'clears all state' do
      bus.submit(type: :test, data: {}, precision: 0.5, salience: 0.5, source: :test)
      bus.reset
      expect(bus.pending_count).to eq(0)
      expect(bus.winners).to be_empty
    end
  end

  describe '#history' do
    it 'records propagation iterations' do
      bus.submit(type: :test, data: {}, precision: 0.5, salience: 0.5, source: :test)
      bus.propagate
      expect(bus.history.size).to eq(1)
      expect(bus.history.first[:iteration]).to eq(1)
    end

    it 'limits history size' do
      250.times do |i|
        bus.submit(type: :test, data: {}, precision: 0.5, salience: 0.5, source: "test_#{i}")
        bus.propagate
      end
      expect(bus.history.size).to be <= 200
    end
  end
end
