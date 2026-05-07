# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/notification_gate/behavioral_evaluator'

RSpec.describe Legion::Gaia::NotificationGate::BehavioralEvaluator do
  subject(:evaluator) { described_class.new }

  describe '#notification_score' do
    it 'returns 0.0 with no signals' do
      expect(evaluator.notification_score).to eq(0.0)
    end

    it 'lowers score when arousal is low' do
      evaluator.update_arousal(0.1)
      expect(evaluator.notification_score).to be < 0.5
    end

    it 'lowers score when idle time is high' do
      evaluator.update_idle_seconds(3600)
      expect(evaluator.notification_score).to eq(0.0)
    end

    it 'has lowest score when both signals indicate inactivity' do
      evaluator.update_arousal(0.0)
      evaluator.update_idle_seconds(3600)
      expect(evaluator.notification_score).to eq(0.0)
    end

    it 'has high score when arousal is high and recently active' do
      evaluator.update_arousal(1.0)
      evaluator.update_idle_seconds(0)
      expect(evaluator.notification_score).to eq(1.0)
    end
  end

  describe '#should_deliver?' do
    it 'delays normal priority when arousal is high' do
      evaluator.update_arousal(1.0)
      evaluator.update_idle_seconds(0)
      expect(evaluator.should_deliver?(priority: :normal)).to be false
    end

    it 'delivers normal priority when arousal is low and idle is high' do
      evaluator.update_arousal(0.0)
      evaluator.update_idle_seconds(3600)
      expect(evaluator.should_deliver?(priority: :normal)).to be true
    end

    it 'delays ambient priority when score is low' do
      evaluator.update_arousal(0.0)
      evaluator.update_idle_seconds(3600)
      expect(evaluator.should_deliver?(priority: :ambient)).to be false
    end

    it 'always delivers urgent regardless of low score' do
      evaluator.update_arousal(0.0)
      evaluator.update_idle_seconds(3600)
      expect(evaluator.should_deliver?(priority: :urgent)).to be true
    end
  end
end
