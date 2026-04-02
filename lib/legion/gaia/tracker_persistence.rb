# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module TrackerPersistence
      extend Legion::Logging::Helper

      FLUSH_INTERVAL = 300 # 5 minutes

      module_function

      def register_tracker(name, tracker:, tags:)
        @trackers ||= {}
        @trackers[name] = { tracker: tracker, tags: tags }
        log.info("TrackerPersistence registered tracker=#{name} tags=#{Array(tags).join(',')}")
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
        log.info("TrackerPersistence flushed dirty trackers count=#{registered_trackers.size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_dirty')
      end

      def flush_all(store: nil)
        return unless store

        registered_trackers.each_value do |entry|
          flush_tracker(entry[:tracker], store: store)
        end
        @last_flush_at = Time.now.utc
        log.info("TrackerPersistence flushed all trackers count=#{registered_trackers.size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_all')
      end

      def hydrate_all(store: nil)
        return unless store

        registered_trackers.each_value do |entry|
          entry[:tracker].from_apollo(store: store)
        end
        log.info("TrackerPersistence hydrated trackers count=#{registered_trackers.size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.hydrate_all')
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
        log.debug("TrackerPersistence flushed tracker=#{tracker.class} entries=#{entries.size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_tracker',
                            tracker_class: tracker.class.to_s)
      end
      private_class_method :flush_tracker
    end
  end
end
