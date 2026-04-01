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

  describe '#partner_offline?' do
    before { evaluator.update(availability: 'Offline') }

    it 'returns true when offline beyond threshold' do
      evaluator.instance_variable_set(:@status_changed_at, Time.now.utc - 3600)
      expect(evaluator.partner_offline?(threshold: 1800)).to be true
    end

    it 'returns false when offline within threshold' do
      evaluator.instance_variable_set(:@status_changed_at, Time.now.utc - 60)
      expect(evaluator.partner_offline?(threshold: 1800)).to be false
    end

    it 'returns false when available' do
      evaluator.update(availability: 'Available')
      expect(evaluator.partner_offline?(threshold: 1800)).to be false
    end
  end

  describe '#offline_duration' do
    it 'returns 0 when no status change recorded' do
      expect(evaluator.offline_duration).to eq(0)
    end

    it 'returns seconds since status changed' do
      evaluator.instance_variable_set(:@status_changed_at, Time.now.utc - 120)
      expect(evaluator.offline_duration).to be_within(2).of(120)
    end
  end

  describe '#status_changed_at tracking' do
    it 'records timestamp on availability change' do
      evaluator.update(availability: 'Available')
      evaluator.update(availability: 'Offline')
      expect(evaluator.status_changed_at).to be_a(Time)
    end

    it 'does not update on same status' do
      evaluator.update(availability: 'Available')
      first = evaluator.status_changed_at
      sleep 0.01
      evaluator.update(availability: 'Available')
      expect(evaluator.status_changed_at).to eq(first)
    end
  end

  describe '#transitioned_online?' do
    it 'returns true on Offline to Available transition' do
      evaluator.update(availability: 'Offline')
      expect(evaluator.transitioned_online?('Available')).to be true
    end

    it 'returns false on Available to Available' do
      evaluator.update(availability: 'Available')
      expect(evaluator.transitioned_online?('Available')).to be false
    end

    it 'returns false on Available to Offline' do
      evaluator.update(availability: 'Available')
      expect(evaluator.transitioned_online?('Offline')).to be false
    end
  end
end
