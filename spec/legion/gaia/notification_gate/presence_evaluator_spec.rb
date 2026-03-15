# frozen_string_literal: true

RSpec.describe Legion::Gaia::NotificationGate::PresenceEvaluator do
  subject(:evaluator) { described_class.new }

  describe '#update and #availability' do
    it 'stores availability and exposes it via accessor' do
      evaluator.update(availability: 'Busy')
      expect(evaluator.availability).to eq('Busy')
    end

    it 'stores activity when provided' do
      evaluator.update(availability: 'Available', activity: 'InACall')
      expect(evaluator.activity).to eq('InACall')
    end

    it 'sets updated_at to a recent UTC time' do
      before = Time.now.utc
      evaluator.update(availability: 'Available')
      after = Time.now.utc
      expect(evaluator.updated_at).to be_between(before, after)
    end
  end

  describe '#delivery_allowed?' do
    context 'when availability is nil (no presence data)' do
      it 'allows all priorities' do
        expect(evaluator.delivery_allowed?(priority: :ambient)).to be true
        expect(evaluator.delivery_allowed?(priority: :normal)).to be true
        expect(evaluator.delivery_allowed?(priority: :critical)).to be true
      end
    end

    context 'when Available' do
      before { evaluator.update(availability: 'Available') }

      it 'allows ambient priority' do
        expect(evaluator.delivery_allowed?(priority: :ambient)).to be true
      end

      it 'allows normal priority' do
        expect(evaluator.delivery_allowed?(priority: :normal)).to be true
      end

      it 'allows critical priority' do
        expect(evaluator.delivery_allowed?(priority: :critical)).to be true
      end
    end

    context 'when DoNotDisturb' do
      before { evaluator.update(availability: 'DoNotDisturb') }

      it 'blocks normal priority' do
        expect(evaluator.delivery_allowed?(priority: :normal)).to be false
      end

      it 'blocks urgent priority' do
        expect(evaluator.delivery_allowed?(priority: :urgent)).to be false
      end

      it 'allows critical priority' do
        expect(evaluator.delivery_allowed?(priority: :critical)).to be true
      end
    end

    context 'when Offline' do
      before { evaluator.update(availability: 'Offline') }

      it 'blocks normal priority' do
        expect(evaluator.delivery_allowed?(priority: :normal)).to be false
      end

      it 'allows critical priority' do
        expect(evaluator.delivery_allowed?(priority: :critical)).to be true
      end
    end

    context 'when Away' do
      before { evaluator.update(availability: 'Away') }

      it 'blocks normal priority' do
        expect(evaluator.delivery_allowed?(priority: :normal)).to be false
      end

      it 'allows urgent priority' do
        expect(evaluator.delivery_allowed?(priority: :urgent)).to be true
      end

      it 'allows critical priority' do
        expect(evaluator.delivery_allowed?(priority: :critical)).to be true
      end
    end

    context 'with unknown presence status' do
      before { evaluator.update(availability: 'SomeUnknownStatus') }

      it 'allows all priorities (defaults to ambient threshold)' do
        expect(evaluator.delivery_allowed?(priority: :ambient)).to be true
        expect(evaluator.delivery_allowed?(priority: :normal)).to be true
      end
    end
  end

  describe '#stale?' do
    context 'when never updated' do
      it 'returns true' do
        expect(evaluator.stale?).to be true
      end
    end

    context 'after a fresh update' do
      before { evaluator.update(availability: 'Available') }

      it 'returns false' do
        expect(evaluator.stale?).to be false
      end
    end

    context 'after enough time has passed' do
      it 'returns true when updated_at is older than max_age' do
        evaluator.update(availability: 'Available')
        evaluator.instance_variable_set(:@updated_at, Time.now.utc - 200)
        expect(evaluator.stale?(max_age: 120)).to be true
      end
    end
  end
end
