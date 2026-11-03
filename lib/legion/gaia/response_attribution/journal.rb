# frozen_string_literal: true

module Legion
  module Gaia
    module ResponseAttribution
      # Persistence methods execute on ResponseAttribution's single state owner.
      module Journal
        def dirty?
          @mutex.synchronize { @revision != @clean_revision }
        end

        def dirty_revision
          @mutex.synchronize { @revision }
        end

        def mark_clean!(revision:)
          @mutex.synchronize { @clean_revision = revision if @revision == revision }
        end

        def to_apollo_entries
          @mutex.synchronize do
            raise IOError, 'attribution hydration unavailable' if @hydration_failed

            @states.map do |identity, state|
              identity_key = Legion::Gaia::TrackerPersistence.identity_tag(identity: identity)
              { content: Legion::JSON.dump(state.merge(identity: identity, identity_key: identity_key)),
                tags: TAGS + [identity_key], access_scope: 'local' }
            end
          end
        end

        def from_apollo(store:)
          Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
            entries = Legion::Gaia::TrackerPersistence.entries_for(store: store, tags: TAGS)
            snapshots = entries.map { |entry| parse_snapshot(entry: entry) }
            @mutex.synchronize do
              snapshots.group_by { |snapshot,| snapshot[:identity].to_s }.each do |identity, candidates|
                snapshot = candidates.max_by do |data, updated_at, id|
                  [data[:erased] ? 1 : 0, data[:revision].to_i, updated_at, id]
                end.first
                restore_snapshot(identity: identity, snapshot: snapshot)
              end
              @hydration_failed = false
            end
          end
          true
        rescue StandardError => e
          @mutex.synchronize { @hydration_failed = true }
          handle_exception(e, level: :warn, operation: 'gaia.response_attribution.from_apollo')
          false
        end

        def reset!
          @mutex.synchronize do
            @states = {}
            @revision = 0
            @clean_revision = 0
            @hydration_failed = false
            @correction_receipts = {}
          end
        end

        private

        def parse_snapshot(entry:)
          content = entry[:content] || entry['content']
          snapshot = content.is_a?(Hash) ? content : Legion::JSON.load(content)
          raise IOError, 'invalid attribution snapshot' unless valid_snapshot?(snapshot: snapshot)

          [snapshot, (entry[:updated_at] || entry['updated_at']).to_s, (entry[:id] || entry['id']).to_i]
        end

        def valid_snapshot?(snapshot:)
          snapshot.is_a?(Hash) && !snapshot[:identity].to_s.empty? &&
            snapshot[:receipts].is_a?(Hash) && snapshot[:proposals].is_a?(Hash)
        end

        def restore_snapshot(identity:, snapshot:)
          current = @states[identity]
          return if current && current[:erased]
          return if current && !snapshot[:erased] && current[:revision].to_i > snapshot[:revision].to_i

          @states[identity] = {
            revision: snapshot[:revision].to_i, erased: snapshot[:erased] == true,
            proposals: snapshot[:proposals].to_h { |key, value| [key.to_s, value] },
            receipts: snapshot[:receipts].to_h { |key, value| [key.to_s, value] }
          }
          @correction_receipts[identity] = @states[identity][:receipts].values.select do |receipt|
            receipt[:feedback_evidence]&.dig(:source).to_s == 'explicit'
          end.last(128)
        end

        def state_for(identity:)
          @states[identity.to_s] ||= { revision: 0, proposals: {}, receipts: {}, erased: false }
        end

        def changed!(state:)
          state[:revision] += 1
          @revision += 1
        end

        def persist(store:)
          return false unless store

          Legion::Gaia::TrackerPersistence.flush_tracker(tracker: self, store: store)
        end
      end
    end
  end
end
