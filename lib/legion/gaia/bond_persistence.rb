# frozen_string_literal: true

module Legion
  module Gaia
    # Extended only by BondRegistry: all live state remains on that registry.
    module BondPersistence
      def to_apollo_entries
        @mutex.synchronize do
          @bonds.values.filter_map do |value|
            next if blocked?(identity: value[:identity])

            identity_key = TrackerPersistence.identity_tag(identity: value[:identity])
            { content: Legion::JSON.dump(value.merge(identity_key: identity_key)),
              tags: BondRegistry::TO_APOLLO_TAGS + [identity_key],
              confidence: value[:strength], access_scope: 'private' }
          end
        end
      end

      def from_apollo(store: nil)
        return false unless hydrate_lifecycle(store: store)

        records = TrackerPersistence.entries_for(store: store, tags: BondRegistry::TO_APOLLO_TAGS)
        records.sort_by { |row| TrackerPersistence.record_order(entry: row) }.each { |row| restore_entry(row: row) }
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.from_apollo')
        false
      end

      def hydrate_lifecycle(store:)
        return mark_lifecycle_unavailable! unless store

        records = TrackerPersistence.entries_for(store: store, tags: BondRegistry::LIFECYCLE_TAGS)
        states = lifecycle_states(records: records)
        @mutex.synchronize do
          @bond_states.merge!(states)
          @lifecycle_ready = true
        end
      rescue StandardError => e
        mark_lifecycle_unavailable!
        handle_exception(e, level: :error, operation: 'gaia.bond_registry.hydrate_lifecycle')
        false
      end

      def persist_lifecycle(identity:, state:, store:)
        raise ArgumentError, 'invalid lifecycle barrier' unless BondRegistry::BLOCKED_STATES.include?(state.to_sym)

        TrackerPersistence::WRITE_LOCK.synchronize do
          set_bond_state(identity, state)
          return false unless store

          identity_key = TrackerPersistence.identity_tag(identity: identity)
          entry = {
            content: Legion::JSON.dump(identity: identity.to_s, identity_key: identity_key, state: state.to_s),
            tags: BondRegistry::LIFECYCLE_TAGS + [identity_key],
            confidence: 1.0, access_scope: 'private', expires_at: '9999-12-31T23:59:59.999Z'
          }
          TrackerPersistence.write_entry(store: store, entry: entry)
        end
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'gaia.bond_registry.persist_lifecycle')
        false
      end

      private

      def lifecycle_states(records:)
        ordered = records.sort_by { |row| TrackerPersistence.record_order(entry: row) }
        ordered.each_with_object({}) do |row, result|
          value = Legion::JSON.load(row[:content])
          unless valid_snapshot_identity?(value: value) && BondRegistry::BLOCKED_STATES.include?(value[:state]&.to_sym)
            raise IOError, 'invalid lifecycle barrier'
          end

          result[value[:identity]] = value[:state].to_sym
        end
      end

      def restore_entry(row:)
        value = Legion::JSON.load(row[:content])
        return unless valid_snapshot_identity?(value: value) && value[:bond]
        return if blocked?(identity: value[:identity])

        value = deserialize_bond(value: value, created_at: row[:created_at])
        @mutex.synchronize { @bonds[value[:identity]] = value }
      rescue StandardError => e
        log.warn("BondRegistry skipped invalid state: #{e.class}")
      end

      def valid_snapshot_identity?(value:)
        return false unless value.is_a?(Hash) && value[:identity].is_a?(String) && !value[:identity].empty?

        return true unless value.key?(:identity_key)

        value[:identity_key] == TrackerPersistence.identity_tag(identity: value[:identity])
      end

      def deserialize_bond(value:, created_at:)
        %i[bond role priority origin preferred_channel last_channel].each { |key| value[key] = value[key]&.to_sym }
        value[:role] = value[:bond]
        value[:priority] ||= :normal
        value[:since] = Time.parse((value[:since] || created_at || '1970-01-01T00:00:00Z').to_s)
        value[:last_reinforced] = Time.parse(value[:last_reinforced].to_s) if value[:last_reinforced]
        value[:strength] = Float(value[:strength] || 0)
        value[:reinforcement_count] = Integer(value[:reinforcement_count] || 0)
        unless value[:strength].finite? && value[:strength].between?(0.0, 1.0) && value[:reinforcement_count] >= 0
          raise ArgumentError, 'invalid bond evidence'
        end

        value
      end
    end
  end
end
