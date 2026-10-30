# frozen_string_literal: true

require 'legion/logging/helper'
require_relative 'bond_registry'
require_relative 'behavioral_synapse'

module Legion
  module Gaia
    module DeathProtocol
      extend Legion::Logging::Helper

      module_function

      # A durable barrier precedes every destructive action. An interrupted attempt
      # remains blocked and retryable; success never means merely clearing RAM.
      def terminate_bond(identity:, confirm:, store: nil)
        raise ArgumentError, 'confirm: must be true to terminate' unless confirm == true
        raise ArgumentError, 'identity is required' if identity.to_s.empty?

        store ||= Legion::Gaia.send(:apollo_local_store)
        TrackerPersistence::WRITE_LOCK.synchronize do
          unless BondRegistry.persist_lifecycle(identity: identity, state: :terminating, store: store)
            return { terminated: false, durable: false, identity: identity.to_s, reason: :barrier_not_persisted,
                     receipt: {} }
          end

          receipt = build_erasure_receipt(identity: identity.to_s, store: store)
          complete = receipt.values.all? { |value| value[:erased] == true || value[:not_applicable] == true }
          complete &&= BondRegistry.persist_lifecycle(identity: identity, state: :terminated, store: store)
          if complete && defined?(Legion::Events) && Legion::Events.respond_to?(:emit)
            Legion::Events.emit('gaia.bond.terminated', identity: identity.to_s, receipt: receipt)
          end
          { terminated: complete, durable: complete, identity: identity.to_s, receipt: receipt }
        end
      end

      def resume_pending(store:)
        pending = BondRegistry.lifecycle_identities.reject { |identity| BondRegistry.bond_state(identity) == :revoked }
        pending.to_h do |identity|
          # Retry even completed barriers: legacy snapshots or interrupted external
          # erasure must not be mistaken for authorization to restore a relationship.
          [identity, terminate_bond(identity: identity, confirm: true, store: store)]
        end
      end

      def build_erasure_receipt(identity:, store:)
        receipt = {
          bond: erase_store(name: :bond) { BondRegistry.erase_partner!(identity: identity) },
          behavioral_synapses: erase_store(name: :behavioral_synapses) do
            { erased: true, count: BehavioralSynapse.erase_partner!(identity: identity), durable: false }
          end,
          session: erase_store(name: :session) do
            session_store = Legion::Gaia.session_store
            session_store ? session_store.erase_partner!(identity: identity) : { not_applicable: true }
          end,
          audit: erase_store(name: :audit) do
            observer = Legion::Gaia::AuditObserver.instance
            observer.erase_partner!(identity: identity)
            remaining = observer.learned_data_for(identity)
            { erased: remaining[:routing_preference].nil? && Array(remaining[:tool_predictions]).empty?,
              durable: false }
          end,
          attribution: erase_store(name: :attribution) { Legion::Gaia.erase_attribution!(identity: identity) },
          preferences: erase_store(name: :preferences) do
            if defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)
              Legion::Extensions::Mesh::Helpers::PreferenceProfile.erase_partner!(identity: identity)
            else
              { not_applicable: true }
            end
          end
        }
        runners = Legion::Gaia.registry&.runner_instances_for(identity: identity) || {}
        runners.each do |name, runner|
          next unless runner.respond_to?(:erase_partner!)

          receipt[name] = erase_store(name: name) { runner.erase_partner!(identity: identity) }
        end
        receipt[:runners] = erase_store(name: :runners) do
          Legion::Gaia.registry ? Legion::Gaia.registry.erase_identity(identity: identity) : { not_applicable: true }
        end
        receipt[:local_snapshots] = TrackerPersistence.erase_identity_entries(identity: identity, store: store)
        receipt
      end
      private_class_method :build_erasure_receipt

      def erase_store(name:)
        result = yield
        return result if result.is_a?(Hash) && (result.key?(:erased) || result[:not_applicable] == true)

        { erased: false, durable: false, reason: :erasure_not_acknowledged }
      rescue StandardError => e
        handle_exception(e, level: :error, operation: 'gaia.death_protocol.erase_store', store: name)
        { erased: false, durable: false, reason: :erasure_failed }
      end
      private_class_method :erase_store
    end
  end
end
