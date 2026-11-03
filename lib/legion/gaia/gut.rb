# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    # H5 — fast per-response conflict detection (v1: correction veto only).
    #
    # Runs at the final-delivery hook (response_return). Deterministic pattern matching
    # against high-strength correction traces and transform-tier behavioral synapses.
    # No LLM calls. Must complete within the latency budget (default 50ms).
    #
    # The gut itself is a behavioral synapse (domain: 'gut') whose autonomy_mode gates
    # what happens: observe = audit-only, filter = restraint directives, transform+ = veto.
    # New partners always start in observe mode (emergent confidence 0.3 → observe tier).
    module Gut
      extend Legion::Logging::Helper

      module_function

      # Check for conflicts between draft response stats and known corrections/synapses.
      #
      # @param identity [String] partner identity
      # @param draft_stats [Hash] stats about the draft response, e.g.
      #   { length_tokens:, format:, domain:, content_flags: [] }
      # @return [Hash, nil]
      #   { conflict: true, confidence: Float, violated_trace_ids: [...], directive: Hash }
      #   { conflict: false }
      #   nil when gut check unavailable (no memory, no synapses, or latency exceeded)
      def check(identity:, draft_stats:)
        return nil if identity.to_s.empty?
        return nil if Legion::Gaia::BondRegistry.blocked?(identity: identity)

        deadline = monotonic_now + (latency_budget_ms / 1000.0)

        gut_synapse = Legion::Gaia::BehavioralSynapse.for(identity: identity.to_s, domain: 'gut')
        gut_mode = gut_mode_for(gut_synapse)

        return nil if gut_mode == :unavailable

        all_violations = collect_violations(identity: identity.to_s, draft_stats: draft_stats, deadline: deadline)
        unless all_violations
          log.debug("[gut] latency budget exceeded identity=#{identity}")
          return nil
        end
        return { conflict: false } if all_violations.empty?

        violated_trace_ids = all_violations.flat_map { |v| v[:trace_ids] }.uniq
        confidence         = all_violations.map { |v| v[:strength] }.max.to_f
        directive          = all_violations.first[:directive] || {}

        log.info("[gut] conflict detected identity=#{identity} " \
                 "violations=#{all_violations.size} confidence=#{confidence.round(3)} " \
                 "mode=#{gut_mode}")

        { conflict: true, confidence: confidence, violated_trace_ids: violated_trace_ids, directive: directive }
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.gut.check', identity: identity)
        nil
      end

      def collect_violations(identity:, draft_stats:, deadline:)
        corrections = correction_traces_for(identity: identity, draft_stats: draft_stats, deadline: deadline)
        return unless corrections

        violations = check_correction_traces(identity: identity, draft_stats: draft_stats,
                                             deadline: deadline, traces: corrections)
        return unless violations

        corrected_domains = corrections.filter_map { |trace| corrected_domain(trace: trace) }
        synapse_violations = check_transform_synapses(identity: identity, draft_stats: draft_stats,
                                                      deadline: deadline, excluded_domains: corrected_domains)
        violations + synapse_violations if synapse_violations
      end

      def latency_budget_ms
        settings = Legion::Gaia.settings
        settings&.dig(:gut, :latency_budget_ms) || 50.0
      end

      def monotonic_now
        ::Process.clock_gettime(::Process::CLOCK_MONOTONIC)
      end

      def deadline_exceeded?(deadline)
        monotonic_now >= deadline
      end

      # Returns the autonomy mode for the gut synapse, or :unavailable if gut should not run.
      # New partners get :observe (observe = audit only, no veto action).
      def gut_mode_for(gut_synapse)
        return :observe if gut_synapse.nil?

        Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(gut_synapse[:confidence].to_f)
      end

      # Compare draft_stats against high-strength correction traces for the partner.
      # Returns array of violation hashes, or nil if deadline exceeded.
      def check_correction_traces(identity:, draft_stats:, deadline:, traces: nil)
        correction_traces = traces || correction_traces_for(identity: identity, draft_stats: draft_stats,
                                                            deadline: deadline)
        return nil unless correction_traces

        correction_traces.filter_map do |trace|
          return nil if deadline_exceeded?(deadline)

          next unless trace_conflicts_with_draft?(trace, draft_stats)

          { trace_ids: [trace[:trace_id].to_s], strength: trace[:strength].to_f,
            directive: directive_from_trace(trace) }
        end
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.gut.check_correction_traces', identity: identity)
        []
      end

      def correction_traces_for(identity:, draft_stats:, deadline:)
        return nil if deadline_exceeded?(deadline)

        traces = memory_correction_traces(identity: identity)
        return nil if deadline_exceeded?(deadline)

        scoped = Legion::Gaia::PartnerModel.scoped_traces(
          identity: identity, conversation_id: draft_stats[:conversation_id], traces: traces
        )
        rejected = scoped.flat_map do |trace|
          payload = trace[:content_payload]
          payload.is_a?(Hash) ? Array(payload[:applied_trace_ids]) : []
        end.map(&:to_s)
        corrected_domains = {}
        scoped.first(correction_trace_limit).select do |trace|
          next false unless correction_trace?(trace)
          next false unless trace[:strength].to_f >= correction_min_strength
          next false if rejected.include?(trace[:trace_id].to_s)

          domain = corrected_domain(trace: trace)
          if domain
            next false if corrected_domains[domain]

            corrected_domains[domain] = true
          end
          true
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.gut.correction_traces_for')
        nil
      end

      def corrected_domain(trace:)
        payload = trace[:content_payload]
        payload[:domain].to_s if payload.is_a?(Hash) && payload[:corrected_constraint] && payload[:domain]
      end

      def memory_correction_traces(identity:)
        runner = Legion::Gaia.registry&.runner_instances_for(identity: identity)&.dig(:Memory_Traces)
        return [] unless runner.respond_to?(:retrieve_by_domain)

        result = runner.retrieve_by_domain(domain_tag: "partner:#{identity}",
                                           min_strength: correction_min_strength, limit: correction_trace_limit)
        Array(result[:traces])
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.gut.memory_correction_traces')
        []
      end

      # Check transform-tier behavioral synapses for conflicts with draft stats.
      # Returns array of violation hashes, or nil if deadline exceeded.
      def check_transform_synapses(identity:, draft_stats:, deadline:, excluded_domains: [])
        return nil if deadline_exceeded?(deadline)

        synapses = Legion::Gaia::BehavioralSynapse.all_for(identity: identity)
        transform_synapses = synapses.first(128).select do |s|
          next false unless s[:identity].to_s == identity && s[:status].to_s == 'active'
          next false if excluded_domains.include?(s[:domain].to_s)

          mode = Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(s[:confidence].to_f)
          %i[transform autonomous].include?(mode)
        end

        transform_synapses.filter_map do |synapse|
          return nil if deadline_exceeded?(deadline)

          next unless synapse_conflicts_with_draft?(synapse, draft_stats)

          { trace_ids: Array(synapse[:evidence_trace_ids]), strength: synapse[:confidence].to_f,
            directive: synapse[:directive].is_a?(Hash) ? synapse[:directive] : {} }
        end
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.gut.check_transform_synapses', identity: identity)
        []
      end

      def correction_trace?(trace)
        return false unless trace.is_a?(Hash)

        trace[:trace_type].to_s == 'correction' ||
          Array(trace[:domain_tags]).any? { |tag| tag.to_s == 'correction' }
      end

      # Checks if a correction trace conflicts with the draft stats.
      # Conflict = the draft exhibits a pattern that the correction explicitly negated.
      def trace_conflicts_with_draft?(trace, draft_stats)
        payload = correction_payload(trace: trace)
        return false unless payload.is_a?(Hash)

        stats = draft_stats.is_a?(Hash) ? draft_stats : {}
        trace_verbosity_conflict?(payload, stats) ||
          trace_format_conflict?(payload, stats) ||
          trace_content_flag_conflict?(payload, stats) ||
          trace_source_conflict?(payload, stats)
      end

      def trace_verbosity_conflict?(payload, stats)
        budget = payload[:budget_tokens] || payload[:max_tokens]
        budget && stats[:length_tokens].to_i > budget.to_i
      end

      def trace_format_conflict?(payload, stats)
        return stats[:format].to_s != payload[:format].to_s if payload[:format] && stats[:format]
        return false unless payload[:rejected_format]

        stats[:format].to_s == payload[:rejected_format].to_s
      end

      def trace_content_flag_conflict?(payload, stats)
        return false unless payload[:rejected_content_flags].is_a?(Array)

        draft_flags = Array(stats[:content_flags]).map(&:to_s)
        rejected    = payload[:rejected_content_flags].map(&:to_s)
        draft_flags.intersect?(rejected)
      end

      def trace_source_conflict?(payload, stats)
        return false unless payload[:correction_type].to_s == 'explicit_negative_feedback'

        applied_ids = Array(stats[:behavioral_synapse_ids]) + Array(stats.dig(:applied_signals,
                                                                              :behavioral_synapse_ids))
        return true if applied_ids.map(&:to_s).intersect?(Array(payload[:applied_synapse_ids]).map(&:to_s))

        applied_trace_ids = Array(stats[:trace_ids]) + Array(stats.dig(:applied_signals, :trace_ids))
        applied_trace_ids.map(&:to_s).intersect?(Array(payload[:applied_trace_ids]).map(&:to_s))
      end

      # Checks if a transform-tier synapse's directive conflicts with draft stats.
      def synapse_conflicts_with_draft?(synapse, draft_stats)
        directive = synapse[:directive]
        return false unless directive.is_a?(Hash)

        stats = draft_stats.is_a?(Hash) ? draft_stats : {}
        synapse_budget_conflict?(directive, stats) || synapse_format_conflict?(directive, stats)
      end

      def synapse_budget_conflict?(directive, stats)
        return false unless directive[:budget_ratio]

        baseline  = stats[:baseline_tokens].to_i
        draft_len = stats[:length_tokens].to_i
        allowed   = (baseline * directive[:budget_ratio].to_f).to_i
        allowed.positive? && draft_len > allowed
      end

      def synapse_format_conflict?(directive, stats)
        return false unless directive[:format] && stats[:format]

        stats[:format].to_s != directive[:format].to_s
      end

      def directive_from_trace(trace)
        payload = correction_payload(trace: trace)
        return {} unless payload.is_a?(Hash)

        payload.slice(:budget_tokens, :max_tokens, :format, :rejected_format, :rejected_content_flags, :correction_type)
      end

      def correction_payload(trace:)
        payload = trace[:content_payload]
        return payload unless payload.is_a?(Hash) && payload[:corrected_constraint].is_a?(Hash)

        payload.merge(payload[:corrected_constraint])
      end

      def correction_min_strength
        settings = Legion::Gaia.settings
        settings&.dig(:gut, :correction_min_strength) || 0.6
      end

      def correction_trace_limit
        settings = Legion::Gaia.settings
        (settings&.dig(:gut, :correction_trace_limit) || 20).to_i.clamp(0, 100)
      end
    end
  end
end
