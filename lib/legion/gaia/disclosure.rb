# frozen_string_literal: true

module Legion
  module Gaia
    module Disclosure
      module_function

      # Full partner model report — what the agent knows, how it was earned, what stays local.
      # Principal-bound: caller reads ONLY their own partner model.
      #
      # @param identity [String] the partner identity key
      # @return [Hash]
      def report(identity:)
        identity_str = identity.to_s

        {
          identity: identity_str,
          bond_state: fetch_bond_state(identity_str),
          behavioral_synapses: fetch_behavioral_synapses(identity_str),
          preferences: fetch_preferences(identity_str),
          calibration_weights: fetch_calibration_weights(identity_str),
          imprint_state: fetch_imprint_state,
          prediction_accuracy: fetch_prediction_accuracy(identity_str),
          data_locality: 'All data is stored locally on this node. Nothing leaves this machine.',
          termination_available: true
        }
      end

      # --- private section ---

      def fetch_bond_state(identity)
        entry = Legion::Gaia::BondRegistry.instance_variable_get(:@bonds)[identity]
        return nil unless entry

        {
          bond: entry[:bond],
          strength: entry[:strength],
          origin: entry[:origin],
          reinforcement_count: entry[:reinforcement_count],
          since: entry[:since],
          preferred_channel: entry[:preferred_channel],
          lifecycle_state: Legion::Gaia::BondRegistry.bond_state(identity)
        }
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_bond_state')
        nil
      end

      def fetch_behavioral_synapses(identity)
        all = Legion::Gaia::BehavioralSynapse.all_for(identity: identity)
        return nil if all.empty?

        all.map do |entry|
          {
            id: entry[:id],
            domain: entry[:domain],
            directive: entry[:directive],
            confidence: entry[:confidence],
            autonomy_mode: Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(entry[:confidence].to_f),
            status: entry[:status],
            origin: entry[:origin],
            consecutive_successes: entry[:consecutive_successes],
            consecutive_failures: entry[:consecutive_failures],
            last_reinforced_at: entry[:last_reinforced_at]
          }
        end
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_behavioral_synapses')
        nil
      end

      def fetch_preferences(identity)
        return nil unless defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)

        result = Legion::Extensions::Mesh::Helpers::PreferenceProfile.for_owner(owner_id: identity)
        return nil unless result.is_a?(Hash) && result[:directives].is_a?(Array)

        result[:directives]
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_preferences')
        nil
      end

      def fetch_calibration_weights(identity)
        return nil unless defined?(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration)
        result = runner.respond_to?(:calibration_weights_for) ? runner.calibration_weights_for(identity: identity) : nil
        result.is_a?(Hash) ? result : nil
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_calibration_weights')
        nil
      end

      def fetch_imprint_state
        return nil unless defined?(Legion::Extensions::Coldstart)
        return nil unless Legion::Extensions::Coldstart.respond_to?(:connected?) &&
                          Legion::Extensions::Coldstart.connected?

        bootstrap = Legion::Extensions::Coldstart::Helpers::Bootstrap.instance
        {
          layer: bootstrap.respond_to?(:current_layer) ? bootstrap.current_layer : nil,
          observations_count: bootstrap.respond_to?(:observation_count) ? bootstrap.observation_count : nil,
          active: bootstrap.respond_to?(:imprint_active?) ? bootstrap.imprint_active? : nil
        }
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_imprint_state')
        nil
      end

      def fetch_prediction_accuracy(identity)
        return nil unless defined?(Legion::Extensions::AgenticInference)
        return nil unless Legion::Extensions::AgenticInference.respond_to?(:accuracy_for)

        Legion::Extensions::AgenticInference.accuracy_for(identity: identity)
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_prediction_accuracy')
        nil
      end

      def handle_exception_quietly(exception, operation)
        return unless defined?(Legion::Logging)

        Legion::Logging.debug("[gaia] #{operation} soft-guarded: #{exception.class}: #{exception.message}")
      end

      module_function :fetch_bond_state, :fetch_behavioral_synapses, :fetch_preferences,
                      :fetch_calibration_weights, :fetch_imprint_state, :fetch_prediction_accuracy,
                      :handle_exception_quietly
    end
  end
end
