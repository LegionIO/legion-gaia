# frozen_string_literal: true

RSpec.describe Legion::Gaia::TrackerPersistence do
  let(:mock_store) { double('Apollo::Local') }

  before { described_class.reset! }

  describe '.register_tracker' do
    it 'registers a tracker with tag prefix and serializer' do
      tracker = double('tracker', dirty?: false)
      described_class.register_tracker(:social_graph, tracker: tracker, tags: ['social_graph'])
      expect(described_class.registered_trackers.keys).to include(:social_graph)
    end
  end

  describe '.flush_dirty' do
    it 'flushes trackers that report dirty' do
      tracker = double('tracker', dirty?: true, to_apollo_entries: [
                         { content: '{"standing":"exemplary"}', tags: %w[social_graph reputation esity] }
                       ], mark_clean!: nil)

      described_class.register_tracker(:social_graph, tracker: tracker, tags: ['social_graph'])

      expect(mock_store).to receive(:upsert)
        .with(hash_including(content: '{"standing":"exemplary"}'))
        .and_return({ success: true })

      described_class.flush_dirty(store: mock_store)
    end

    it 'skips clean trackers' do
      tracker = double('tracker', dirty?: false)
      described_class.register_tracker(:social_graph, tracker: tracker, tags: ['social_graph'])

      expect(mock_store).not_to receive(:upsert)
      described_class.flush_dirty(store: mock_store)
    end
  end

  describe '.flush_all' do
    it 'flushes all trackers regardless of dirty state' do
      tracker = double('tracker', dirty?: false, to_apollo_entries: [
                         { content: '{}', tags: ['test'] }
                       ], mark_clean!: nil)

      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])

      expect(mock_store).to receive(:upsert).and_return({ success: true })
      described_class.flush_all(store: mock_store)
    end
  end

  describe '.hydrate_all' do
    it 'calls from_apollo on each registered tracker' do
      tracker = double('tracker', dirty?: false)
      expect(tracker).to receive(:from_apollo).with(store: mock_store)

      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])
      described_class.hydrate_all(store: mock_store)
    end

    it 'handles missing store gracefully' do
      tracker = double('tracker', dirty?: false)
      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])
      expect { described_class.hydrate_all(store: nil) }.not_to raise_error
    end
  end

  describe '.last_flush_at' do
    it 'tracks when the last flush occurred' do
      expect(described_class.last_flush_at).to be_nil

      tracker = double('tracker', dirty?: true, to_apollo_entries: [], mark_clean!: nil)
      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])
      described_class.flush_dirty(store: mock_store)

      expect(described_class.last_flush_at).to be_within(2).of(Time.now.utc)
    end
  end

  describe '.should_flush?' do
    it 'returns true when never flushed' do
      expect(described_class.should_flush?).to be true
    end

    it 'returns false when recently flushed' do
      tracker = double('tracker', dirty?: true, to_apollo_entries: [], mark_clean!: nil)
      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])
      described_class.flush_dirty(store: mock_store)
      expect(described_class.should_flush?).to be false
    end
  end
end
