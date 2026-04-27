# frozen_string_literal: true

RSpec.describe Legion::Gaia::NotificationGate do
  let(:frame_normal) do
    Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :cli, metadata: {})
  end

  let(:frame_urgent) do
    Legion::Gaia::OutputFrame.new(content: 'urgent', channel_id: :cli, metadata: { priority: :urgent })
  end

  let(:frame_critical) do
    Legion::Gaia::OutputFrame.new(content: 'critical', channel_id: :cli, metadata: { priority: :critical })
  end

  let(:frame_low) do
    Legion::Gaia::OutputFrame.new(content: 'low', channel_id: :cli, metadata: { priority: :low })
  end

  describe 'outside quiet hours' do
    subject(:gate) { described_class.new(settings: { notifications: { enabled: true } }) }

    before { allow(gate.schedule_evaluator).to receive(:quiet?).and_return(false) }

    it 'returns :deliver for normal priority' do
      expect(gate.evaluate(frame_normal)).to eq(:deliver)
    end

    it 'returns :deliver for urgent priority' do
      expect(gate.evaluate(frame_urgent)).to eq(:deliver)
    end
  end

  describe 'during quiet hours' do
    subject(:gate) { described_class.new(settings: { notifications: { enabled: true, priority_override: :urgent } }) }

    before { allow(gate.schedule_evaluator).to receive(:quiet?).and_return(true) }

    it 'returns :delay for normal priority' do
      expect(gate.evaluate(frame_normal)).to eq(:delay)
    end

    it 'returns :delay for low priority' do
      expect(gate.evaluate(frame_low)).to eq(:delay)
    end

    it 'returns :deliver for urgent priority (priority override)' do
      expect(gate.evaluate(frame_urgent)).to eq(:deliver)
    end

    it 'returns :deliver for critical priority (always overrides)' do
      expect(gate.evaluate(frame_critical)).to eq(:deliver)
    end
  end

  describe '#enqueue and #pending_count' do
    subject(:gate) { described_class.new }

    it 'increases pending_count after enqueue' do
      expect { gate.enqueue(frame_normal) }.to change(gate, :pending_count).from(0).to(1)
    end

    it 'tracks multiple enqueued frames' do
      gate.enqueue(frame_normal)
      gate.enqueue(frame_urgent)
      expect(gate.pending_count).to eq(2)
    end
  end

  describe '#process_delayed' do
    subject(:gate) { described_class.new(settings: { notifications: { enabled: true } }) }

    context 'when quiet hours end' do
      before do
        allow(gate.schedule_evaluator).to receive(:quiet?).and_return(false)
        gate.enqueue(frame_normal)
        gate.enqueue(frame_low)
      end

      it 'returns all pending frames' do
        result = gate.process_delayed
        expect(result).to contain_exactly(frame_normal, frame_low)
      end

      it 'drops pending_count to 0' do
        gate.process_delayed
        expect(gate.pending_count).to eq(0)
      end
    end

    context 'while still quiet' do
      before do
        allow(gate.schedule_evaluator).to receive(:quiet?).and_return(true)
        gate.enqueue(frame_normal)
      end

      it 'returns empty array' do
        expect(gate.process_delayed).to be_empty
      end

      it 'leaves pending_count unchanged' do
        expect { gate.process_delayed }.not_to change(gate, :pending_count)
      end
    end
  end

  describe '#flush' do
    subject(:gate) { described_class.new }

    it 'returns all enqueued frames and clears the queue' do
      gate.enqueue(frame_normal)
      gate.enqueue(frame_urgent)
      result = gate.flush
      expect(result).to contain_exactly(frame_normal, frame_urgent)
      expect(gate.pending_count).to eq(0)
    end
  end

  describe '#status' do
    subject(:gate) { described_class.new }

    it 'returns schedule, presence, and behavioral gate state for /api/gaia/status' do
      allow(gate.schedule_evaluator).to receive(:quiet?).and_return(false)
      gate.update_presence(availability: 'Away')
      gate.update_behavioral(arousal: 0.4)

      expect(gate.status).to eq({
                                  schedule: true,
                                  presence: 'Away',
                                  behavioral: 0.4
                                })
    end
  end

  describe 'when enabled: false' do
    subject(:gate) { described_class.new(settings: { notifications: { enabled: false } }) }

    before { allow(gate.schedule_evaluator).to receive(:quiet?).and_return(true) }

    it 'always returns :deliver regardless of schedule' do
      expect(gate.evaluate(frame_normal)).to eq(:deliver)
    end

    it 'always returns :deliver for low priority' do
      expect(gate.evaluate(frame_low)).to eq(:deliver)
    end
  end
end
