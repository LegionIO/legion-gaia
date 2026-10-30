# frozen_string_literal: true

require 'digest'
require 'monitor'
require 'time'
require 'legion/json'
require 'legion/logging/helper'

module Legion
  module Gaia
    module TrackerPersistence
      extend Legion::Logging::Helper

      FLUSH_INTERVAL = 300
      WRITE_LOCK = Monitor.new

      module_function

      def register_tracker(name, tracker:, tags:)
        mutex.synchronize do
          @trackers ||= {}
          @trackers[name] = { tracker: tracker, tags: tags }
        end
      end

      def unregister_tracker(name:)
        WRITE_LOCK.synchronize { mutex.synchronize { @trackers&.delete(name) } }
      end

      def registered_trackers
        mutex.synchronize { (@trackers || {}).dup }
      end

      def flush_dirty(store: nil)
        return false unless store

        WRITE_LOCK.synchronize do
          results = registered_trackers.values.map do |entry|
            tracker = entry[:tracker]
            !tracker.dirty? || flush_tracker(tracker: tracker, store: store)
          rescue StandardError => e
            handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_dirty')
            false
          end
          mutex.synchronize { @last_flush_at = Time.now.utc } if results.all?
          results.all?
        end
      end

      def flush_all(store: nil)
        return false unless store

        WRITE_LOCK.synchronize do
          results = registered_trackers.values.map { |entry| flush_tracker(tracker: entry[:tracker], store: store) }
          mutex.synchronize { @last_flush_at = Time.now.utc } if results.all?
          results.all?
        end
      end

      def hydrate_all(store: nil)
        mutex.synchronize do
          @hydration_succeeded = false
          @last_hydration_attempt_at = Time.now.utc if store
        end

        # Barriers must be loaded before any private tracker can restore data.
        return false unless BondRegistry.hydrate_lifecycle(store: store)

        results = registered_trackers.values.map do |entry|
          entry[:tracker].from_apollo(store: store) != false
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.hydrate_all')
          false
        end
        mutex.synchronize { @hydration_succeeded = results.all? }
      end

      def hydration_due?
        mutex.synchronize do
          !@hydration_succeeded &&
            (@last_hydration_attempt_at.nil? || Time.now.utc - @last_hydration_attempt_at >= FLUSH_INTERVAL)
        end
      end

      def last_flush_at
        mutex.synchronize { @last_flush_at }
      end

      def should_flush?
        mutex.synchronize { @last_flush_at.nil? || Time.now.utc - @last_flush_at >= FLUSH_INTERVAL }
      end

      def reset!
        mutex.synchronize do
          @trackers = {}
          @last_flush_at = nil
          @hydration_succeeded = false
          @last_hydration_attempt_at = nil
        end
      end

      def flush_tracker(tracker:, store:)
        return false unless store

        WRITE_LOCK.synchronize do
          return false unless BondRegistry.lifecycle_ready?

          revision = tracker.dirty_revision if tracker.respond_to?(:dirty_revision)
          entries = tracker.to_apollo_entries
          results = entries.map { |entry| write_entry(entry: entry, store: store) }
          return false unless results.all?

          # A legacy tracker's unconditional mark_clean! can lose a concurrent update.
          # Keep it dirty until its owner implements revision-aware acknowledgement.
          tracker.mark_clean!(revision: revision) unless revision.nil?
          true
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.flush_tracker',
                            tracker_class: tracker.class.to_s)
        false
      end

      def write_entry(entry:, store:)
        result = store.upsert(**entry.slice(:content, :tags, :confidence, :expires_at),
                              source_channel: 'gaia', access_scope: entry.fetch(:access_scope, 'local'),
                              identity_canonical_name: entry[:identity_canonical_name],
                              identity_principal_id: entry[:identity_principal_id], identity_id: entry[:identity_id])
        success = result == true || (result.is_a?(Hash) && result[:success] == true && !result[:error])
        if success && entry[:expires_at] && apollo_local?(store: store)
          tags = Legion::JSON.dump(entry[:tags].sort)
          Legion::Data::Local.connection[:local_knowledge].where(tags: tags).update(expires_at: entry[:expires_at])
        end
        log.warn('TrackerPersistence write was not acknowledged') unless success
        success
      end

      # Local knowledge has a finite retrieval TTL. Relationship state and deletion
      # barriers must survive it, so read the existing local dataset without expiry.
      def entries_for(store:, tags:)
        if apollo_local?(store: store)
          dataset = Legion::Data::Local.connection[:local_knowledge]
          tags.each do |tag|
            dataset = dataset.where(Sequel.lit(
                                      'EXISTS (SELECT 1 FROM json_each(local_knowledge.tags) ' \
                                      'WHERE json_each.value = ?)', tag
                                    ))
          end
          return dataset.all
        end

        result = store.query_by_tags(tags: tags, limit: nil)
        raise IOError, 'private tracker hydration failed' unless result.is_a?(Hash) && result[:success] == true

        result.fetch(:results)
      end

      def identity_tag(identity:)
        "i:#{Digest::SHA256.hexdigest(identity.to_s)[0, 62]}"
      end

      def record_order(entry:)
        [entry[:updated_at].to_s, entry[:created_at].to_s, entry[:id].to_i, entry[:content].to_s]
      end

      # Apollo has no public erasure API. Use its existing Data Local transaction,
      # including the FTS index and source links; never pretend a missing delete worked.
      def erase_identity_entries(identity:, store:)
        return { erased: false, durable: false, reason: :local_erasure_unavailable } unless apollo_local?(store: store)

        WRITE_LOCK.synchronize do
          db = Legion::Data::Local.connection
          count = 0
          db.transaction do
            rows = db[:local_knowledge].all.select { |row| owned_entry?(entry: row, identity: identity) }
            rows.each do |row|
              db.run("DELETE FROM local_knowledge_fts WHERE rowid = #{Integer(row[:id])}")
              db[:local_source_links].where(entry_id: row[:id]).delete if db.table_exists?(:local_source_links)
              count += db[:local_knowledge].where(id: row[:id]).delete
            end
          end
          { erased: true, durable: true, count: count }
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.tracker_persistence.erase_identity_entries')
        { erased: false, durable: false, reason: :local_erasure_failed }
      end

      def owned_entry?(entry:, identity:)
        tags = entry[:tags].is_a?(String) ? Legion::JSON.load(entry[:tags]) : Array(entry[:tags])
        return false if tags.include?('gaia_lifecycle')
        return true if tags.include?(identity_tag(identity: identity))

        content = Legion::JSON.load(entry[:content])
        content.is_a?(Hash) && content[:identity].to_s == identity.to_s
      rescue StandardError => e
        log.debug("TrackerPersistence retained unparseable local entry: #{e.class}")
        false
      end
      private_class_method :owned_entry?

      def apollo_local?(store:)
        defined?(Legion::Apollo::Local) && store.equal?(Legion::Apollo::Local) &&
          defined?(Legion::Data::Local) && Legion::Data::Local.connected?
      end
      private_class_method :apollo_local?

      def mutex
        @mutex ||= Mutex.new
      end
      private_class_method :mutex
    end
  end
end
