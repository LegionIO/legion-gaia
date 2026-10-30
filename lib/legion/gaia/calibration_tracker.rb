# frozen_string_literal: true

require 'json'
require 'legion/json'
require 'legion/logging/helper'
require_relative 'bond_registry'
require_relative 'tracker_persistence'

module Legion
  module Gaia
    # The provider owns calibration math and live state; this adapter supplies the
    # identity boundary absent from its global-tag persistence contract.
    class CalibrationTracker
      include Legion::Logging::Helper

      TAGS = %w[gaia_calibration].freeze

      def initialize(identity:, tracker:)
        raise ArgumentError, 'identity is required' if identity.to_s.empty?

        @identity = identity.to_s.dup.freeze
        @tracker = tracker
        @identity_tag = TrackerPersistence.identity_tag(identity: @identity)
      end

      # Baseline updates do not mark the revisionless provider dirty. Conservatively
      # snapshot every periodic flush rather than silently drop those live changes.
      def dirty?
        true
      end

      def mark_clean!
        @tracker.mark_clean!
      end

      def to_apollo_entries
        return [] if BondRegistry.blocked?(identity: @identity)

        @tracker.to_apollo_entries.map do |entry|
          content = Legion::JSON.load(entry.fetch(:content))
          raise TypeError, 'calibration snapshot must be an object' unless content.is_a?(Hash)

          entry.merge(content: Legion::JSON.dump(content.merge(identity: @identity, identity_key: @identity_tag)),
                      tags: (Array(entry[:tags]) + TAGS + [@identity_tag]).uniq,
                      access_scope: 'private', identity_canonical_name: nil,
                      identity_principal_id: nil, identity_id: nil)
        end
      end

      def from_apollo(store:)
        return false unless store && BondRegistry.lifecycle_ready?
        return true if BondRegistry.blocked?(identity: @identity)

        TrackerPersistence::WRITE_LOCK.synchronize do
          rows = TrackerPersistence.entries_for(store: store, tags: TAGS + [@identity_tag])
          return true if rows.empty?

          weights, history = latest_snapshots(rows: rows)
          return false unless weights
          return false unless @tracker.from_apollo(store: QueryView.new(entries: [weights])) == true

          @tracker.history.replace(history) if @tracker.respond_to?(:history) && @tracker.history.is_a?(Hash)
          true
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.calibration_tracker.from_apollo')
        false
      end

      private

      def latest_snapshots(rows:)
        weights = nil
        history = {}
        rows.sort_by { |entry| TrackerPersistence.record_order(entry: entry) }.reverse_each do |entry|
          content = Legion::JSON.load(entry[:content])
          next unless content.is_a?(Hash) && content[:identity] == @identity && content[:identity_key] == @identity_tag

          if valid_weights?(content: content)
            weights ||= entry
          elsif valid_history?(content: content)
            history[content[:advisory_type]] ||= content[:events].map { |event| event.transform_keys(&:to_s) }
          end
        rescue StandardError => e
          log.warn("CalibrationTracker skipped invalid snapshot: #{e.class}")
        end
        [weights, history]
      end

      def valid_history?(content:)
        content[:advisory_type].is_a?(String) && content[:events].is_a?(Array) && content[:events].all?(Hash)
      end

      def valid_weights?(content:)
        return false unless content[:weights].is_a?(Hash)
        return false unless content[:weights].values.all? do |value|
          value.is_a?(Numeric) && value.finite? && value.between?(0.0, 1.0)
        end
        return true if content[:baselines].nil?

        content[:baselines].is_a?(Hash) && content[:baselines].values.all? do |value|
          value.nil? || (value.is_a?(Numeric) && value.finite? && value >= 0)
        end
      end

      # Read-only provider query view. It cannot fall through to a global query.
      class QueryView
        def initialize(entries:)
          @entries = entries.map do |entry|
            tags = entry[:tags].is_a?(String) ? Legion::JSON.load(entry[:tags]) : Array(entry[:tags])
            entry.merge(tags: tags)
          end
        end

        def query(tags: [], **)
          results = @entries.select { |entry| Array(tags).all? { |tag| entry[:tags].include?(tag) } }
          { success: true, results: results }
        end
      end
    end
  end
end
