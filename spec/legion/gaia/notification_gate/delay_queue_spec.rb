# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/notification_gate/delay_queue'

RSpec.describe Legion::Gaia::NotificationGate::DelayQueue do
  let(:frame) { Legion::Gaia::OutputFrame.new(content: 'test', channel_id: :cli) }
  subject(:queue) { described_class.new }

  describe '#enqueue + #size + #pending' do
    it 'tracks enqueued frames' do
      queue.enqueue(frame)
      expect(queue.size).to eq(1)
    end

    it 'returns entries with expected keys from pending' do
      queue.enqueue(frame)
      entries = queue.pending
      expect(entries.size).to eq(1)
      entry = entries.first
      expect(entry[:frame]).to eq(frame)
      expect(entry[:queued_at]).to be_a(Time)
      expect(entry[:retry_count]).to eq(0)
    end

    it 'enqueues multiple frames' do
      3.times { queue.enqueue(frame) }
      expect(queue.size).to eq(3)
    end
  end

  describe 'eviction when full' do
    subject(:queue) { described_class.new(max_size: 5) }

    it 'does not exceed max_size' do
      6.times { queue.enqueue(frame) }
      expect(queue.size).to eq(5)
    end

    it 'returns the evicted entry on overflow' do
      oldest = Legion::Gaia::OutputFrame.new(content: 'oldest', channel_id: :cli)
      queue.enqueue(oldest)
      4.times { queue.enqueue(frame) }

      evicted = queue.enqueue(frame)
      expect(evicted).not_to be_nil
      expect(evicted[:frame]).to eq(oldest)
    end

    it 'returns nil when queue is not full' do
      result = queue.enqueue(frame)
      expect(result).to be_nil
    end
  end

  describe '#drain_expired' do
    it 'returns expired entries and removes them from the queue' do
      queue.enqueue(frame)

      # Backdating the queued_at to simulate expiry
      entry = queue.pending.first
      entry[:queued_at] = Time.now.utc - 14_401

      expired = queue.drain_expired
      expect(expired.size).to eq(1)
      expect(queue.size).to eq(0)
    end

    it 'does not remove non-expired entries' do
      queue.enqueue(frame)
      expired = queue.drain_expired
      expect(expired).to be_empty
      expect(queue.size).to eq(1)
    end

    it 'only removes entries older than max_delay' do
      old_frame = Legion::Gaia::OutputFrame.new(content: 'old', channel_id: :cli)
      new_frame = Legion::Gaia::OutputFrame.new(content: 'new', channel_id: :cli)

      queue.enqueue(old_frame)
      queue.enqueue(new_frame)

      queue.pending.first[:queued_at] = Time.now.utc - 14_401

      expired = queue.drain_expired
      expect(expired.size).to eq(1)
      expect(expired.first[:frame]).to eq(old_frame)
      expect(queue.size).to eq(1)
      expect(queue.pending.first[:frame]).to eq(new_frame)
    end
  end

  describe '#requeue' do
    it 'preserves the original queued_at while incrementing retry_count' do
      queued_at = Time.now.utc - 14_401
      queue.requeue(frame: frame, queued_at: queued_at, retry_count: 2)

      entry = queue.pending.first
      expect(entry[:queued_at]).to eq(queued_at)
      expect(entry[:retry_count]).to eq(3)
    end
  end

  describe '#flush' do
    it 'returns all entries' do
      3.times { queue.enqueue(frame) }
      all = queue.flush
      expect(all.size).to eq(3)
    end

    it 'clears the queue after flush' do
      3.times { queue.enqueue(frame) }
      queue.flush
      expect(queue.size).to eq(0)
    end

    it 'returns empty array when queue is empty' do
      expect(queue.flush).to eq([])
    end
  end

  describe '#clear' do
    it 'discards all entries' do
      3.times { queue.enqueue(frame) }
      queue.clear
      expect(queue.size).to eq(0)
    end

    it 'returns empty array after clear' do
      3.times { queue.enqueue(frame) }
      queue.clear
      expect(queue.pending).to be_empty
    end
  end
end
