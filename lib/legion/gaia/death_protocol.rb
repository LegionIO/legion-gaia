# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module DeathProtocol
      extend Legion::Logging::Helper

      module_function

      # The single entry point for bond termination.
      # confirm: must be true (explicit consent gate).
      # Returns: { terminated: true, identity:, receipt: { store => result } }
      def terminate_bond(identity:, confirm:)
        raise ArgumentError, 'confirm: must be true to terminate' unless confirm == true

        identity_str = identity.to_s

        # 1. Set bond state to :terminating (blocks new writes)
        Legion::Gaia::BondRegistry.set_bond_state(identity_str, :terminating)

        # 2. Walk every store's erase_partner!
        receipt = build_erasure_receipt(identity_str)

        # 3. Set bond state to :terminated
        Legion::Gaia::BondRegistry.set_bond_state(identity_str, :terminated)

        # 4. Emit event
        if defined?(Legion::Events) && Legion::Events.respond_to?(:emit)
          Legion::Events.emit('gaia.bond.terminated', identity: identity_str, receipt: receipt)
        end

        # 5. Log receipt
        log.info("[gaia] bond terminated identity=#{identity_str} stores=#{receipt.keys.size}")

        { terminated: true, identity: identity_str, receipt: receipt }
      end

      private

      def build_erasure_receipt(identity_str)
        {
          bond: erase_store(:bond) { Legion::Gaia::BondRegistry.erase_partner!(identity: identity_str) },
          behavioral_synapses: erase_store(:behavioral_synapses) do
            Legion::Gaia::BehavioralSynapse.erase_partner!(identity: identity_str)
          end,
          session: erase_store(:session) do
            Legion::Gaia.session_store&.erase_partner!(identity: identity_str)
          end,
          audit: erase_store(:audit) do
            Legion::Gaia::AuditObserver.instance.erase_partner!(identity: identity_str)
          end,
          attribution: erase_store(:attribution) { Legion::Gaia.erase_attribution!(identity: identity_str) },
          calibration: erase_calibration(identity_str),
          preferences: erase_preferences(identity_str),
          memory_traces: erase_memory_traces(identity_str),
          predictions: erase_predictions(identity_str),
          trust: erase_trust(identity_str)
        }
      end

      def erase_store(name)
        result = yield
        result.is_a?(Hash) ? result : { erased: true }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=#{name} error=#{e.message}")
        raise
      end

      def erase_calibration(identity_str)
        unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)
          return { skipped: true, reason: :calibration_unavailable }
        end

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)
        return { skipped: true, reason: :no_erase_method } unless runner.respond_to?(:erase_partner!)

        erase_store(:calibration) { runner.erase_partner!(identity: identity_str) }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=calibration error=#{e.message}")
        raise
      end

      def erase_preferences(identity_str)
        unless defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)
          return { skipped: true, reason: :preferences_unavailable }
        end

        klass = Legion::Extensions::Mesh::Helpers::PreferenceProfile
        return { skipped: true, reason: :no_erase_method } unless klass.respond_to?(:erase_partner!)

        erase_store(:preferences) { klass.erase_partner!(identity: identity_str) }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=preferences error=#{e.message}")
        raise
      end

      def erase_memory_traces(identity_str)
        unless defined?(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)
          return { skipped: true, reason: :memory_trace_unavailable }
        end

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Memory::Trace::Runners::Traces)
        return { skipped: true, reason: :no_erase_method } unless runner.respond_to?(:erase_partner!)

        erase_store(:memory_traces) { runner.erase_partner!(identity: identity_str) }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=memory_traces error=#{e.message}")
        raise
      end

      def erase_predictions(identity_str)
        unless defined?(Legion::Extensions::Agentic::Prediction::Helpers::Store)
          return { skipped: true, reason: :predictions_unavailable }
        end

        store = Legion::Extensions::Agentic::Prediction::Helpers::Store
        return { skipped: true, reason: :no_erase_method } unless store.respond_to?(:erase_partner!)

        erase_store(:predictions) { store.erase_partner!(identity: identity_str) }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=predictions error=#{e.message}")
        raise
      end

      def erase_trust(identity_str)
        unless defined?(Legion::Extensions::Agentic::Social::Trust::Helpers::TrustStore)
          return { skipped: true, reason: :trust_unavailable }
        end

        store = Legion::Extensions::Agentic::Social::Trust::Helpers::TrustStore
        return { skipped: true, reason: :no_erase_method } unless store.respond_to?(:erase_partner!)

        erase_store(:trust) { store.erase_partner!(identity: identity_str) }
      rescue StandardError => e
        log.error("[gaia] death_protocol store=trust error=#{e.message}")
        raise
      end

      module_function :build_erasure_receipt, :erase_store, :erase_calibration, :erase_preferences,
                      :erase_memory_traces, :erase_predictions, :erase_trust
    end
  end
end
