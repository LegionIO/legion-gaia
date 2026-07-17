# frozen_string_literal: true

module Legion
  module Gaia
    module PartnerModel
      # Working-memory slot competition (§12.4).
      # Only filter/transform/autonomous tier synapses compete — observe-tier synapses are
      # tracked separately via observe_mode_entries and never consume working-memory slots.
      MAX_WORKING_MEMORY_SLOTS = 7

      # Source-confidence defaults for preference candidates.
      PREFERENCE_SOURCE_CONFIDENCE = {
        explicit: 1.0,
        preference_learning: 0.75,
        llm_inference: 0.65,
        observation: 0.55
      }.freeze

      module_function

      # Build the working-memory slot array for this identity.
      #
      # @param identity [String, Symbol] the partner identity key
      # @param synapses [Array, nil] BehavioralSynapse entries; fetched from store if nil
      # @param traces   [Array, nil] episodic/semantic trace hashes from lex-agentic-memory
      # @param preferences [Array, nil] PreferenceProfile directives with :source and :content
      # @return [Array<Hash>] at most MAX_WORKING_MEMORY_SLOTS slot hashes, sorted by score desc
      def build(identity:, synapses: nil, traces: nil, preferences: nil)
        identity_str = identity.to_s
        candidates = []
        candidates.concat(synapse_candidates(identity: identity_str, synapses: synapses))
        candidates.concat(trace_candidates(traces))
        candidates.concat(preference_candidates(preferences))

        max_slots = Legion::Gaia.settings&.dig(:partner_model, :max_slots) || MAX_WORKING_MEMORY_SLOTS

        candidates
          .sort_by { |c| -slot_score(c) }
          .first(max_slots)
          .map { |c| c.slice(:type, :domain, :content, :strength, :source_id, :autonomy_mode) }
      end

      # Returns observe-tier synapses for this identity (transparency surface — not in working memory).
      #
      # @param identity [String, Symbol]
      # @return [Array<Hash>]
      def observe_mode_entries(identity:)
        identity_str = identity.to_s
        all = Legion::Gaia::BehavioralSynapse.all_for(identity: identity_str)
        all.select { |entry| autonomy_tier(entry[:confidence]) == :observe }
           .map do |entry|
             {
               type: :synapse,
               domain: entry[:domain],
               content: entry[:directive],
               strength: entry[:confidence],
               source_id: entry[:id],
               autonomy_mode: :observe
             }
           end
      end

      # --- private helpers ---

      def synapse_candidates(identity:, synapses:)
        entries = synapses || Legion::Gaia::BehavioralSynapse.all_for(identity: identity)
        entries.filter_map do |entry|
          tier = autonomy_tier(entry[:confidence])
          next unless %i[filter transform autonomous].include?(tier)

          {
            type: :synapse,
            domain: entry[:domain],
            content: entry[:directive],
            strength: entry[:confidence].to_f,
            emotional_intensity: entry[:emotional_intensity].to_f,
            source_id: entry[:id],
            autonomy_mode: tier
          }
        end
      end

      def trace_candidates(traces)
        return [] unless traces.is_a?(Array)

        traces.map do |trace|
          strength = (trace[:strength] || trace[:confidence]).to_f
          intensity = (trace[:emotional_intensity] || 0.5).to_f
          {
            type: :trace,
            domain: Array(trace[:domain_tags]).first.to_s,
            content: trace[:content_payload],
            strength: strength,
            emotional_intensity: intensity,
            source_id: trace[:trace_id],
            autonomy_mode: nil
          }
        end
      end

      def preference_candidates(preferences)
        return [] unless preferences.is_a?(Array)

        preferences.map do |pref|
          source_key = pref[:source].to_s.to_sym
          strength = PREFERENCE_SOURCE_CONFIDENCE.fetch(source_key, 0.55)
          {
            type: :preference,
            domain: pref[:domain].to_s,
            content: pref[:content] || pref[:directive],
            strength: strength,
            emotional_intensity: 0.3,
            source_id: pref[:id],
            autonomy_mode: nil
          }
        end
      end

      def slot_score(candidate)
        strength  = candidate[:strength].to_f
        intensity = candidate[:emotional_intensity].to_f
        strength * (1.0 + intensity)
      end

      def autonomy_tier(confidence)
        Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(confidence.to_f)
      end

      module_function :synapse_candidates, :trace_candidates, :preference_candidates,
                      :slot_score, :autonomy_tier
    end
  end
end
