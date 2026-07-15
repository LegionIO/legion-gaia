# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    # TrackerPattern persistence wrapper for the bond stores in BondRegistry.
    # Implements dirty/clean, to_apollo_entries, and from_apollo for
    # integration with TrackerPersistence's flush and hydration cycles.
    module BondTracker
      extend Legion::Logging::Helper

      module_function

      def dirty?
        @dirty ||= false
      end

      def mark_clean!
        @dirty = false
      end

      def dirty!
        @dirty = true
      end

      def to_apollo_entries
        return [] unless BondRegistry.respond_to?(:stores)

        entries = []
        BondRegistry.stores.each_value do |store|
          next unless store.respond_to?(:dirty?) && store.dirty?

          store_entries = store.to_apollo_entries
          entries.concat(store_entries)
          store.mark_clean!
        end
        @dirty = false
        entries
      end

      def from_apollo(store:)
        result = store.query(text: 'bond_evidence', tags: %w[bond gaia])
        return unless result.is_a?(Hash) && result[:success] && result[:results]&.any?

        result[:results].each do |entry|
          BondRegistry.hydrate_store(entry) if BondRegistry.respond_to?(:hydrate_store)
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_tracker.from_apollo')
      end
    end
  end
end
