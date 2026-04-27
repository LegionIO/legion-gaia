# frozen_string_literal: true

RSpec.describe Legion::Gaia::TickHistory do
  subject(:history) { described_class.new }

  describe 'MAX_ENTRIES' do
    it 'is 200' do
      expect(described_class::MAX_ENTRIES).to eq(200)
    end
  end

  describe '#record' do
    it 'does nothing with a non-hash result' do
      expect { history.record(nil) }.not_to raise_error
      expect(history.size).to eq(0)
    end

    it 'does nothing when results key is missing' do
      expect { history.record({ other: :data }) }.not_to raise_error
      expect(history.size).to eq(0)
    end

    it 'does nothing when results is not a hash' do
      expect { history.record({ results: 'bad' }) }.not_to raise_error
      expect(history.size).to eq(0)
    end

    it 'records one event per phase in the result' do
      history.record({
                       results: {
                         sensory_processing: { elapsed_ms: 12, status: :ok },
                         emotional_evaluation: { elapsed_ms: 7, status: :ok }
                       }
                     })
      expect(history.size).to eq(2)
    end

    it 'stores phase name as a string' do
      history.record({ results: { sensory_processing: { elapsed_ms: 5, status: :ok } } })
      entry = history.recent(limit: 1).first
      expect(entry[:phase]).to eq('sensory_processing')
    end

    it 'stores elapsed_ms as duration_ms' do
      history.record({ results: { action_selection: { elapsed_ms: 42, status: :ok } } })
      entry = history.recent(limit: 1).first
      expect(entry[:duration_ms]).to eq(42)
    end

    it 'stores status from phase data' do
      history.record({ results: { prediction_engine: { elapsed_ms: 3, status: :skipped } } })
      entry = history.recent(limit: 1).first
      expect(entry[:status]).to eq(:skipped)
    end

    it 'defaults missing status and duration to UI-safe values' do
      history.record({ results: { prediction_engine: {} } })
      entry = history.recent(limit: 1).first
      expect(entry[:status]).to eq(:completed)
      expect(entry[:duration_ms]).to eq(0.0)
    end

    it 'stores an ISO8601 timestamp' do
      history.record({ results: { identity_entropy_check: { elapsed_ms: 1, status: :ok } } })
      entry = history.recent(limit: 1).first
      expect(entry[:timestamp]).to match(/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/)
    end

    it 'skips phase entries whose data is not a hash' do
      history.record({ results: { bad_phase: 'not_a_hash', good_phase: { elapsed_ms: 1, status: :ok } } })
      expect(history.size).to eq(1)
      expect(history.recent.first[:phase]).to eq('good_phase')
    end

    context 'when entries exceed MAX_ENTRIES' do
      it 'evicts oldest entries to stay at MAX_ENTRIES' do
        (described_class::MAX_ENTRIES + 10).times do |i|
          history.record({ results: { "phase_#{i}": { elapsed_ms: i, status: :ok } } })
        end
        expect(history.size).to eq(described_class::MAX_ENTRIES)
      end

      it 'keeps the most recent entries' do
        (described_class::MAX_ENTRIES + 5).times do |i|
          history.record({ results: { marker_phase: { elapsed_ms: i, status: :ok } } })
        end
        recent = history.recent(limit: 5)
        expect(recent.map { |e| e[:duration_ms] }).to eq([200, 201, 202, 203, 204])
      end
    end
  end

  describe '#recent' do
    before do
      10.times do |i|
        history.record({ results: { "phase_#{i}": { elapsed_ms: i, status: :ok } } })
      end
    end

    it 'returns the last N entries' do
      expect(history.recent(limit: 3).size).to eq(3)
    end

    it 'returns up to all entries when limit exceeds size' do
      expect(history.recent(limit: 100).size).to eq(10)
    end

    it 'defaults to returning up to 50 entries' do
      expect(history.recent.size).to eq(10)
    end

    it 'returns a dup so mutations do not affect internal state' do
      result = history.recent
      result.clear
      expect(history.size).to eq(10)
    end

    it 'returns entries in insertion order (oldest first within the limit)' do
      entries = history.recent(limit: 3)
      durations = entries.map { |e| e[:duration_ms] }
      expect(durations).to eq([7, 8, 9])
    end

    it 'does not corrupt internal state when caller mutates a returned entry' do
      original_phase = history.recent(limit: 1).first[:phase]
      returned = history.recent(limit: 1)
      returned.first[:phase] = 'mutated'
      expect(history.recent(limit: 1).first[:phase]).to eq(original_phase)
    end

    it 'returns frozen string values so in-place string mutation is not possible' do
      entry = history.recent(limit: 1).first
      expect(entry[:phase]).to be_frozen
      expect(entry[:timestamp]).to be_frozen
    end
  end

  describe '#size' do
    it 'returns 0 for a new instance' do
      expect(history.size).to eq(0)
    end

    it 'reflects total events recorded across ticks' do
      history.record({ results: { a: { elapsed_ms: 1, status: :ok }, b: { elapsed_ms: 2, status: :ok } } })
      expect(history.size).to eq(2)
    end
  end

  describe 'thread safety' do
    it 'handles concurrent writes without raising' do
      threads = 10.times.map do |i|
        Thread.new do
          5.times do |j|
            history.record({ results: { "phase_#{i}_#{j}": { elapsed_ms: j, status: :ok } } })
          end
        end
      end
      expect { threads.each(&:join) }.not_to raise_error
    end

    it 'handles concurrent reads and writes without raising' do
      writer = Thread.new do
        100.times do |i|
          history.record({ results: { "phase_#{i}": { elapsed_ms: i, status: :ok } } })
        end
      end
      reader = Thread.new do
        100.times { history.recent(limit: 10) }
      end
      expect { [writer, reader].each(&:join) }.not_to raise_error
    end
  end
end
