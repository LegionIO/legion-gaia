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

    it 'keeps trackers dirty when Apollo returns a failed upsert response' do
      tracker = double('tracker', dirty?: true, to_apollo_entries: [
                         { content: '{"standing":"exemplary"}', tags: %w[social_graph reputation esity] }
                       ])

      described_class.register_tracker(:social_graph, tracker: tracker, tags: ['social_graph'])

      expect(mock_store).to receive(:upsert)
        .with(hash_including(content: '{"standing":"exemplary"}'))
        .and_return({ success: false })
      expect(tracker).not_to receive(:mark_clean!)

      described_class.flush_dirty(store: mock_store)
      expect(described_class.last_flush_at).to be_nil
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

    it 'does not advance when a flush fails' do
      tracker = double('tracker', dirty?: true, to_apollo_entries: [
                         { content: '{}', tags: ['test'] }
                       ])

      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])
      allow(mock_store).to receive(:upsert).and_return({ success: false })

      described_class.flush_dirty(store: mock_store)

      expect(described_class.last_flush_at).to be_nil
    end
  end

  describe '.flush_tracker (entry-provided identity)' do
    before { described_class.reset! }

    it 'passes entry-provided access_scope and identity to store.upsert' do
      tracker = double('tracker', dirty?: true, mark_clean!: nil,
                                  to_apollo_entries: [
                                    { content: '{"pref":"direct"}', tags: %w[preference],
                                      access_scope: 'private', identity_principal_id: 42,
                                      identity_id: 99, identity_canonical_name: 'alice' }
                                  ])
      store = double('store')
      described_class.register_tracker(:prefs, tracker: tracker, tags: ['preference'])

      expect(store).to receive(:upsert).with(
        hash_including(
          access_scope: 'private',
          identity_principal_id: 42,
          identity_id: 99,
          identity_canonical_name: 'alice'
        )
      ).and_return({ success: true })

      described_class.flush_dirty(store: store)
    end

    it 'falls back to global access_scope when entry does not specify it' do
      tracker = double('tracker', dirty?: true, mark_clean!: nil,
                                  to_apollo_entries: [
                                    { content: '{}', tags: %w[test] }
                                  ])
      store = double('store')
      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])

      expect(store).to receive(:upsert).with(
        hash_including(access_scope: 'global')
      ).and_return({ success: true })

      described_class.flush_dirty(store: store)
    end

    it 'does not overwrite entry identity with process identity when entry provides identity' do
      stub_const('Legion::Identity::Process', Module.new do
        extend self

        define_method(:identity_hash) do
          { canonical_name: 'system', db_principal_id: 1, db_identity_id: 1 }
        end
      end)

      tracker = double('tracker', dirty?: true, mark_clean!: nil,
                                  to_apollo_entries: [
                                    { content: '{}', tags: %w[test],
                                      identity_principal_id: 42, identity_canonical_name: 'alice' }
                                  ])
      store = double('store')
      described_class.register_tracker(:test, tracker: tracker, tags: ['test'])

      expect(store).to receive(:upsert).with(
        hash_including(identity_principal_id: 42, identity_canonical_name: 'alice')
      ).and_return({ success: true })

      described_class.flush_dirty(store: store)
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
