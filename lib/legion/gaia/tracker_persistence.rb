# frozen_string_literal: true

module Legion
  module Gaia
    module TrackerPersistence
      FLUSH_INTERVAL = 300 # 5 minutes

      module_function

      def register_tracker(name, tracker:, tags:)
        @trackers ||= {}
        @trackers[name] = { tracker: tracker, tags: tags }
      end

      def registered_trackers
        @trackers || {}
      end

      def flush_dirty(store: nil)
        return unless store

        registered_trackers.each_value do |entry|
          tracker = entry[:tracker]
          next unless tracker.dirty?

          flush_tracker(tracker, store: store)
        end
        @last_flush_at = Time.now.utc
      rescue StandardError => e
        Legion::Logging.warn "TrackerPersistence flush_dirty error: #{e.message}" if defined?(Legion::Logging)
      end

      def flush_all(store: nil)
        return unless store

        registered_trackers.each_value do |entry|
          flush_tracker(entry[:tracker], store: store)
        end
        @last_flush_at = Time.now.utc
      rescue StandardError => e
        Legion::Logging.warn "TrackerPersistence flush_all error: #{e.message}" if defined?(Legion::Logging)
      end

      def hydrate_all(store: nil)
        return unless store

        registered_trackers.each_value do |entry|
          entry[:tracker].from_apollo(store: store)
        end
      rescue StandardError => e
        Legion::Logging.warn "TrackerPersistence hydrate error: #{e.message}" if defined?(Legion::Logging)
      end

      def last_flush_at
        @last_flush_at
      end

      def should_flush?
        return true if @last_flush_at.nil?

        (Time.now.utc - @last_flush_at) >= FLUSH_INTERVAL
      end

      def reset!
        @trackers = {}
        @last_flush_at = nil
      end

      def flush_tracker(tracker, store:)
        entries = tracker.to_apollo_entries
        entries.each do |entry|
          store.upsert(content: entry[:content], tags: entry[:tags],
                       source_channel: 'gaia', confidence: entry.fetch(:confidence, 0.9))
        end
        tracker.mark_clean!
      rescue StandardError => e
        Legion::Logging.warn "TrackerPersistence flush error for #{tracker.class}: #{e.message}" if defined?(Legion::Logging)
      end
      private_class_method :flush_tracker
    end
  end
end
