# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'

module Legion
  module Gaia
    # H6 — prediction pre-staging with emotional modulation (§12.8).
    #
    # Reads pending predictions from lex-agentic-inference (if available).
    # Actionable predictions (confidence >= threshold) trigger pre-staged RAG retrieval,
    # capped at 25% of total entries.
    #
    # Emotional modulation: negative-valence anticipations defer when the partner's affect
    # baseline is low (soft-guarded on lex-agentic-affect).
    #
    # Entropy guard: no resolution under high identity entropy (consistent with H2).
    # Soft-guarded throughout: returns nil when dependencies are absent.
    module Anticipation
      extend Legion::Logging::Helper

      # Threshold below which the partner's affect baseline is considered "low".
      LOW_AFFECT_BASELINE = 0.3

      # Cap on pre-staged entries as a fraction of total RAG entries.
      PRESTAGE_CAP_RATIO = 0.25

      module_function

      # Build anticipation context for advisory.
      #
      # @param identity [String] partner identity
      # @param context [Hash] current request context, e.g. { rag_entry_count:, entropy: }
      # @return [Hash, nil]
      #   { prediction_id:, content:, confidence:, pre_staged: [...] }
      #   nil when lex-agentic-inference not loaded or no actionable predictions
      def build(identity:, context:)
        return nil unless inference_available?

        runner = inference_runner
        result = runner.pending_predictions(identity: identity.to_s)
        predictions = Array(result[:predictions])
        return nil if predictions.empty?

        actionable = predictions.select { |p| p[:confidence].to_f >= actionable_threshold }
        return nil if actionable.empty?

        # Pick the highest-confidence actionable prediction
        best = actionable.max_by { |p| p[:confidence].to_f }

        # Emotional modulation: defer negative-valence anticipation when affect baseline is low
        if deferred?(identity: identity, anticipation: best)
          log.info("[anticipation] deferred identity=#{identity} prediction_id=#{best[:prediction_id].to_s[0, 8]} " \
                   'reason=emotional_state')
          return nil
        end

        pre_staged = build_prestaged(context: context, prediction: best)

        log.info("[anticipation] built identity=#{identity} prediction_id=#{best[:prediction_id].to_s[0, 8]} " \
                 "confidence=#{best[:confidence].to_f.round(3)} pre_staged=#{pre_staged.size}")

        {
          prediction_id: best[:prediction_id],
          content: best[:description] || best[:context].to_s,
          confidence: best[:confidence].to_f,
          pre_staged: pre_staged
        }
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.anticipation.build', identity: identity)
        nil
      end

      # Resolve a pending anticipation against the partner's actual next input.
      #
      # Grades the prediction as :correct, :incorrect, or :partial and records the outcome.
      # Skipped under high identity entropy.
      #
      # @param identity [String] partner identity
      # @param prediction_id [String] UUID of the prediction to resolve
      # @param actual [String] the partner's actual input
      # @return [Hash, nil]
      #   { resolved: true/false, outcome:, prediction_id: }
      #   nil when dependencies unavailable
      def resolve(identity:, prediction_id:, actual:)
        return nil unless inference_available?

        identity_str = identity.to_s

        if high_entropy?(identity: identity_str)
          log.info("[anticipation] resolve skipped identity=#{identity_str} reason=high_entropy")
          return { resolved: false, reason: :high_entropy, prediction_id: prediction_id }
        end

        outcome = grade_prediction(prediction_id: prediction_id, actual: actual, identity: identity_str)
        runner = inference_runner
        result = runner.resolve_prediction(prediction_id: prediction_id, outcome: outcome,
                                           actual: actual, identity: identity_str)

        log.info("[anticipation] resolved identity=#{identity_str} prediction_id=#{prediction_id.to_s[0, 8]} " \
                 "outcome=#{outcome}")

        result
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.anticipation.resolve',
                            identity: identity, prediction_id: prediction_id)
        nil
      end

      # Check if an anticipation should be deferred due to emotional state.
      #
      # Deferred when the anticipation has negative emotional context AND the partner's
      # current affect baseline is low (§12.8 emotional modulation).
      #
      # @param identity [String] partner identity
      # @param anticipation [Hash] prediction entry with optional :emotional_context
      # @return [Boolean]
      def deferred?(identity:, anticipation:)
        return false unless anticipation.is_a?(Hash)

        anticipation_valence = extract_valence(anticipation)
        return false unless anticipation_valence < 0.0

        affect_baseline_low?(identity: identity.to_s)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.anticipation.deferred', identity: identity)
        false
      end

      def inference_available?
        defined?(Legion::Extensions::Agentic::Inference::Prediction::Runners::Prediction) == 'constant'
      end

      def inference_runner
        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Inference::Prediction::Runners::Prediction)
        runner
      end

      def actionable_threshold
        settings = Legion::Gaia.settings
        settings&.dig(:anticipation, :actionable_threshold) ||
          (defined?(Legion::Extensions::Agentic::Inference::Prediction::Helpers::Modes::PREDICTION_CONFIDENCE_MIN) &&
           Legion::Extensions::Agentic::Inference::Prediction::Helpers::Modes::PREDICTION_CONFIDENCE_MIN) ||
          0.65
      end

      # Builds pre-staged RAG entries capped at 25% of total context entries.
      def build_prestaged(context:, prediction:)
        return [] unless context.is_a?(Hash)

        rag_count = context[:rag_entry_count].to_i
        return [] if rag_count.zero?

        cap = [(rag_count * PRESTAGE_CAP_RATIO).ceil, 1].max
        prediction_context = prediction[:context]
        return [] unless prediction_context.is_a?(Hash) && prediction_context[:pre_stage_entries].is_a?(Array)

        prediction_context[:pre_stage_entries].first(cap)
      end

      # Grade a prediction as :correct, :incorrect, or :partial.
      def grade_prediction(prediction_id:, actual:, identity:)
        return :incorrect unless inference_available?

        runner = inference_runner
        pred_result = runner.get_prediction(prediction_id: prediction_id, identity: identity)
        return :incorrect unless pred_result[:found]

        prediction = pred_result[:prediction]
        predicted = prediction[:description].to_s.downcase.strip
        actual_str = actual.to_s.downcase.strip

        return :incorrect if predicted.empty? || actual_str.empty?

        if actual_str.include?(predicted) || predicted.include?(actual_str)
          :correct
        elsif partial_match?(predicted, actual_str)
          :partial
        else
          :incorrect
        end
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.anticipation.grade_prediction',
                            prediction_id: prediction_id)
        :incorrect
      end

      def partial_match?(predicted, actual)
        pred_words = predicted.split(/\s+/).reject(&:empty?)
        actual_words = actual.split(/\s+/).reject(&:empty?)
        return false if pred_words.empty? || actual_words.empty?

        overlap = pred_words & actual_words
        ratio = overlap.size.to_f / [pred_words.size, actual_words.size].min
        ratio >= 0.5
      end

      # Returns true when the partner's affect baseline is below LOW_AFFECT_BASELINE.
      def affect_baseline_low?(identity:)
        return false unless defined?(Legion::Extensions::Agentic::Affect::Empathy::Helpers::ModelStore)

        model_store = Legion::Extensions::Agentic::Affect::Empathy::Helpers::ModelStore.new
        model = model_store.get(identity)
        return false unless model.respond_to?(:emotional_state)

        negative_states = %i[stressed anxious frustrated overwhelmed sad]
        negative_states.include?(model.emotional_state)
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.anticipation.affect_baseline_low', identity: identity)
        false
      end

      def extract_valence(anticipation)
        ctx = anticipation[:emotional_context]
        if ctx.is_a?(Hash)
          ctx[:valence].to_f
        elsif ctx.is_a?(Numeric)
          ctx.to_f
        else
          0.0
        end
      end

      def high_entropy?(identity:)
        return false unless defined?(Legion::Extensions::Agentic::Self::Helpers::IdentityFingerprint)

        runner = Object.new
        runner.extend(Legion::Extensions::Agentic::Self::Helpers::IdentityFingerprint)
        entropy = runner.identity_entropy(identity: identity)
        threshold = Legion::Gaia.settings&.dig(:identity, :high_entropy_threshold) || 0.7
        entropy.to_f >= threshold
      rescue StandardError
        false
      end
    end
  end
end
