# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module PartnerModel
      extend Legion::Logging::Helper

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

      DOMAIN_ADVISORY_TYPES = {
        'tone' => :tone_adjustment,
        'formality' => :tone_adjustment,
        'brevity' => :verbosity_adjustment,
        'verbosity' => :verbosity_adjustment,
        'detail' => :verbosity_adjustment,
        'length' => :verbosity_adjustment,
        'format' => :format_adjustment,
        'code' => :format_adjustment
      }.freeze
      INFERRED_SOURCES = %i[inferred preference_learning llm_inference observation].freeze

      module_function

      # Build the working-memory slot array for this identity.
      #
      # @param identity [String, Symbol] the partner identity key
      # @param synapses [Array, nil] BehavioralSynapse entries; fetched from store if nil
      # @param traces   [Array, nil] episodic/semantic trace hashes from lex-agentic-memory
      # @param preferences [Array, nil] PreferenceProfile directives with :source and :content
      # @return [Array<Hash>] at most MAX_WORKING_MEMORY_SLOTS slot hashes, sorted by score desc
      def build(identity:, synapses: nil, traces: nil, preferences: nil, conversation_id: nil)
        identity_str = identity.to_s
        return [] if identity_str.empty?
        return [] if Legion::Gaia::BondRegistry.blocked?(identity: identity_str)

        preferences ||= preferences_for(identity: identity_str)
        traces = scoped_traces(identity: identity_str, conversation_id: conversation_id, traces: traces)
        rejected_ids = rejected_source_ids(traces: traces)

        candidates = synapse_candidates(identity: identity_str, synapses: synapses)
        candidates.concat(trace_candidates(traces: traces))
        candidates.concat(preference_candidates(preferences, identity: identity_str))
        candidates.reject! { |candidate| rejected_ids.include?(candidate[:source_id].to_s) }
        candidates.each { |candidate| candidate[:advisory_type] = advisory_type_for(candidate: candidate) }
        apply_calibration_weights!(candidates: candidates, identity: identity_str)
        select_slots(candidates: candidates)
      end

      def rejected_source_ids(traces:)
        traces.flat_map do |trace|
          payload = trace[:content_payload]
          next [] unless Array(trace[:domain_tags]).include?('correction') && payload.is_a?(Hash)

          Array(payload[:applied_synapse_ids]) + Array(payload[:applied_trace_ids])
        end.map(&:to_s)
      end

      def select_slots(candidates:)
        strongest = candidates.group_by { |candidate| candidate[:domain] }.values.flat_map do |entries|
          precedence = entries.map { |entry| source_precedence(candidate: entry) }.max
          entries.select { |entry| source_precedence(candidate: entry) == precedence }
        end
        limit = Legion::Gaia.settings&.dig(:partner_model, :max_slots) || MAX_WORKING_MEMORY_SLOTS
        strongest.sort_by { |candidate| [-source_precedence(candidate: candidate), -slot_score(candidate)] }
                 .first(limit.to_i.clamp(0, MAX_WORKING_MEMORY_SLOTS))
                 .map do |candidate|
          candidate.slice(:type, :domain, :content, :strength, :source_id, :autonomy_mode, :source, :advisory_type)
        end
      end

      def scoped_traces(identity:, conversation_id:, traces:)
        corrections = Legion::Gaia::ResponseAttribution.corrections_for(identity: identity,
                                                                        conversation_id: conversation_id)
        entries = corrections + Array(traces).first(128)
        scoped = entries.filter_map do |entry|
          next unless entry.is_a?(Hash)

          trace = entry[:trace] || entry
          next unless trace.is_a?(Hash) && Array(trace[:domain_tags]).include?("partner:#{identity}")

          payload = trace[:content_payload]
          scope = payload[:conversation_id] if payload.is_a?(Hash)
          next if scope && scope.to_s != conversation_id.to_s

          trace
        end
        scoped.uniq do |trace|
          payload = trace[:content_payload]
          (payload[:feedback_id] if payload.is_a?(Hash)) || trace[:trace_id]
        end.first(128)
      end

      def preferences_for(identity:)
        return nil unless defined?(Legion::Extensions::Mesh::Helpers::PreferenceProfile)

        profile = Legion::Extensions::Mesh::Helpers::PreferenceProfile
        runner = Legion::Gaia.registry&.runner_instances_for(identity: identity)&.dig(:Memory_Traces)
        return nil unless runner.respond_to?(:retrieve_by_domain)

        result = runner.retrieve_by_domain(domain_tag: "owner:#{identity}", limit: 128)
        Array(result[:traces]).first(128).filter_map do |trace|
          tags = Array(trace[:domain_tags])
          next unless tags.include?("owner:#{identity}") && tags.include?('preference')

          preference = profile.parse_preference_trace(trace)
          next unless preference.is_a?(Hash)

          preference.merge(identity: identity, id: trace[:trace_id], content: preference[:value])
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.partner_model.preferences_for')
        nil
      end

      def source_precedence(candidate:)
        return 3 if candidate[:source] == :correction
        return 2 if candidate[:source] == :explicit && candidate[:type] == :preference
        return 1 if candidate[:source] == :explicit

        0
      end

      def advisory_type_for(candidate:)
        return candidate[:advisory_type].to_sym unless candidate[:advisory_type].to_s.empty?

        DOMAIN_ADVISORY_TYPES.fetch(candidate[:domain].to_s) do
          candidate[:source] == :memory ? :context_injection : :partner_hint
        end
      end

      def apply_calibration_weights!(candidates:, identity:)
        return unless defined?(Legion::Extensions::Agentic::Social::Calibration::Helpers::Constants)

        runner = Legion::Gaia.calibration_runner_for(identity: identity, create: false)
        return unless runner.respond_to?(:calibration_weights)

        result = runner.calibration_weights(identity: identity)
        return unless result.is_a?(Hash) && result[:success] == true && result[:weights].is_a?(Hash)

        constants = Legion::Extensions::Agentic::Social::Calibration::Helpers::Constants
        weights = result[:weights]
        candidates.reject! do |candidate|
          next false unless INFERRED_SOURCES.include?(candidate[:source])

          type = candidate[:advisory_type]
          weight = weights.key?(type) ? weights[type] : weights[type.to_s]
          next false unless weight.is_a?(Numeric) && weight.finite?

          weight = weight.clamp(0.0, 1.0)
          candidate[:selection_weight] = weight / constants::NEUTRAL_SCORE
          weight < constants::SUPPRESSION_THRESHOLD
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.partner_model.apply_calibration_weights')
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
             { type: :synapse, domain: entry[:domain], content: entry[:directive],
               strength: entry[:confidence], source_id: entry[:id], autonomy_mode: :observe }
           end
      end

      # --- private helpers ---

      def synapse_candidates(identity:, synapses:)
        entries = synapses || Legion::Gaia::BehavioralSynapse.all_for(identity: identity)
        entries.first(128).filter_map do |entry|
          next unless entry[:identity].to_s == identity
          next unless entry[:status].to_s == 'active'

          tier = autonomy_tier(entry[:confidence])
          next unless %i[filter transform autonomous].include?(tier)

          { type: :synapse, domain: entry[:domain], content: entry[:directive],
            strength: entry[:confidence].to_f, emotional_intensity: entry[:emotional_intensity].to_f,
            source: entry[:origin].to_s == 'explicit' ? :explicit : :inferred,
            source_id: entry[:id], autonomy_mode: tier, advisory_type: entry[:advisory_type] }
        end
      end

      # Traces have already passed the single ownership and conversation boundary in scoped_traces.
      def trace_candidates(traces:)
        corrected_domains = {}
        traces.filter_map do |trace|
          candidate = trace_candidate(trace: trace)
          next unless candidate

          domain = candidate[:domain]
          if candidate[:source] == :correction && !domain.empty?
            next if corrected_domains[domain]

            corrected_domains[domain] = true
          end
          candidate
        end
      end

      def trace_candidate(trace:)
        tags = Array(trace[:domain_tags])
        payload = trace[:content_payload]
        correction = tags.include?('correction') && payload.is_a?(Hash)
        content = correction ? payload[:corrected_constraint] : payload
        return if content.nil? || (content.respond_to?(:empty?) && content.empty?)

        domain = payload[:domain] if payload.is_a?(Hash)
        domain ||= tags.find { |tag| tag != 'correction' && !tag.start_with?('partner:') }
        { type: :trace, domain: domain.to_s, content: content,
          strength: (trace[:strength] || trace[:confidence]).to_f,
          emotional_intensity: (trace[:emotional_intensity] || 0.5).to_f,
          source_id: trace[:trace_id], autonomy_mode: nil,
          source: correction ? :correction : :memory, advisory_type: trace[:advisory_type] }
      end

      def preference_candidates(preferences, identity:)
        return [] unless preferences.is_a?(Array)

        preferences.first(128).filter_map do |pref|
          next unless (pref[:identity] || pref[:owner_id]).to_s == identity
          next if pref[:revoked] || pref[:status].to_s == 'revoked'

          source_key = pref[:source].to_s.to_sym
          {
            type: :preference, domain: pref[:domain].to_s,
            content: pref[:content] || pref[:directive],
            strength: PREFERENCE_SOURCE_CONFIDENCE.fetch(source_key, 0.55),
            emotional_intensity: 0.3, source_id: pref[:id], autonomy_mode: nil,
            source: source_key, advisory_type: pref[:advisory_type]
          }
        end
      end

      def slot_score(candidate)
        strength  = candidate[:strength].to_f
        intensity = candidate[:emotional_intensity].to_f
        strength * (1.0 + intensity) * candidate.fetch(:selection_weight, 1.0)
      end

      def autonomy_tier(confidence)
        Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(confidence.to_f)
      end

      module_function :synapse_candidates, :trace_candidates, :preference_candidates,
                      :slot_score, :autonomy_tier
    end
  end
end
