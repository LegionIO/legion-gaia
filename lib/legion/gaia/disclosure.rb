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
        return { available: false, reason: :missing_identity } if identity_str.empty?

        local_store_available = defined?(Legion::Apollo::Local) && Legion::Apollo::Local.respond_to?(:started?) && Legion::Apollo::Local.started?

        {
          identity: identity_str,
          bond_state: fetch_bond_state(identity_str),
          behavioral_synapses: fetch_behavioral_synapses(identity_str),
          preferences: fetch_preferences(identity_str),
          calibration_weights: fetch_calibration_weights(identity_str),
          imprint_state: fetch_imprint_state(identity: identity_str),
          prediction_accuracy: fetch_prediction_accuracy(identity_str),
          attribution: Legion::Gaia::ResponseAttribution.status_for(identity: identity_str),
          data_locality: {
            partner_store: local_store_available ? :apollo_local : :memory_only,
            external_processing: :deployment_dependent,
            explanation: 'Selected partner context may be sent to the configured model provider. ' \
                         'Local persistence does not establish provider retention or backup deletion.'
          },
          termination_available: defined?(Legion::Gaia::DeathProtocol) == 'constant',
          deletion_scope: :gaia_managed_state
        }
      end

      # --- private section ---

      def fetch_bond_state(identity)
        entry = Legion::Gaia::BondRegistry.entry(identity: identity)
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

        Legion::Gaia::PartnerModel.preferences_for(identity: identity)
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_preferences')
        nil
      end

      def fetch_calibration_weights(identity)
        return nil unless Legion::Gaia.respond_to?(:calibration_runner_for)

        runner = Legion::Gaia.calibration_runner_for(identity: identity)
        return nil unless runner.respond_to?(:calibration_weights)

        result = runner.calibration_weights(identity: identity)
        result.is_a?(Hash) && result[:success] == true ? result[:weights] : nil
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_calibration_weights')
        nil
      end

      def fetch_imprint_state(identity:)
        # The published Coldstart singleton is node-scoped, not evidence about this
        # human. Only an explicitly identity-aware live implementation can report it.
        runners = Legion::Gaia.registry&.runner_instances_for(identity: identity) || {}
        runner = runners.values.find do |candidate|
          candidate.respond_to?(:imprint_state_for)
        end
        runner&.imprint_state_for(identity: identity)
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_imprint_state')
        nil
      end

      def fetch_prediction_accuracy(identity)
        runner = Legion::Gaia::Anticipation.inference_runner(identity: identity)
        return nil unless runner.respond_to?(:prediction_accuracy)

        runner.prediction_accuracy(identity: identity)
      rescue StandardError => e
        Legion::Gaia::Disclosure.handle_exception_quietly(e, 'disclosure.fetch_prediction_accuracy')
        nil
      end

      def handle_exception_quietly(exception, operation)
        return unless defined?(Legion::Logging)

        Legion::Logging.debug("[gaia] #{operation} unavailable: #{exception.class}")
      end

      module_function :fetch_bond_state, :fetch_behavioral_synapses, :fetch_preferences,
                      :fetch_calibration_weights, :fetch_imprint_state, :fetch_prediction_accuracy,
                      :handle_exception_quietly
    end
  end
end
