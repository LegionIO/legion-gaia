# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module TrackerPersistence
      extend Legion::Logging::Helper

      FLUSH_INTERVAL = 300 # 5 minutes

      module_function

      def register_tracker(name, tracker:, tags:)
        mutex.synchronize do
          @trackers ||= {}
          @trackers[name] = { tracker: tracker, tags: tags }
        end
        log.info("TrackerPersistence registered tracker=#{name} tags=#{Array(tags).join(',')}")
      end

      def registered_trackers
        mutex.synchronize { (@trackers || {}).dup }
      end

      def flush_dirty(store: nil)
        return unless store

        failed = false
        flushed = 0
        entries = registered_trackers.values
        entries.each do |entry|
          tracker = entry[:tracker]
          next unless tracker.dirty?

          if flush_tracker(tracker, store: store)
            flushed += 1
          else
            failed = true
          end
        end
        mutex.synchronize { @last_flush_at = Time.now.utc } unless failed
        if failed
          log.warn("TrackerPersistence flush_dirty completed with errors flushed=#{flushed}")
        else
          log.info("TrackerPersistence flushed dirty trackers flushed=#{flushed}")
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_dirty')
      end

      def flush_all(store: nil)
        return unless store

        failed = false
        entries = registered_trackers.values
        entries.each do |entry|
          failed ||= !flush_tracker(entry[:tracker], store: store)
        end
        mutex.synchronize { @last_flush_at = Time.now.utc } unless failed
        log.info("TrackerPersistence flushed all trackers count=#{entries.size}")
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
        mutex.synchronize { @last_flush_at }
      end

      def should_flush?
        mutex.synchronize do
          return true if @last_flush_at.nil?

          (Time.now.utc - @last_flush_at) >= FLUSH_INTERVAL
        end
      end

      def reset!
        mutex.synchronize do
          @trackers = {}
          @last_flush_at = nil
        end
      end

      def flush_tracker(tracker, store:)
        entries = tracker.to_apollo_entries
        results = entries.map do |entry|
          store.upsert(content: entry[:content], tags: entry[:tags],
                       source_channel: 'gaia', confidence: entry.fetch(:confidence, 0.9))
        end

        unless results.all? { |result| upsert_succeeded?(result) }
          log.error("TrackerPersistence flush failed tracker=#{tracker.class} entries=#{entries.size}")
          return false
        end

        tracker.mark_clean!
        log.debug("TrackerPersistence flushed tracker=#{tracker.class} entries=#{entries.size}")
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_tracker',
                            tracker_class: tracker.class.to_s)
        false
      end
      private_class_method :flush_tracker

      def upsert_succeeded?(result)
        return false if result.nil? || result == false
        return true unless result.is_a?(Hash)

        return false if result[:error] || result['error']
        return false if result.key?(:success) && result[:success] == false
        return false if result.key?('success') && result['success'] == false

        true
      end
      private_class_method :upsert_succeeded?

      def mutex
        @mutex ||= Mutex.new
      end
      private_class_method :mutex
    end
  end
end
