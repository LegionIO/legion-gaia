# frozen_string_literal: true

module Legion
  module Gaia
    module Advisory
      module_function

      # Fast in-memory advisory. NEVER makes LLM calls.
      # Returns Hash with optional keys: system_prompt, routing_hint,
      # context_window, tool_hint, suppress, valence
      def advise(caller:, conversation_id: nil, messages: nil) # rubocop:disable Lint/UnusedMethodArgument
        return nil unless Gaia.started?

        advisory = {}
        advisory[:valence] = Gaia.last_valences if Gaia.last_valences
        merge_tick_data!(advisory, Gaia.registry&.tick_host&.last_tick_result)
        merge_observer_data!(advisory, caller)
        advisory.compact
      rescue StandardError => e
        Legion::Logging.warn("GAIA advisory failed: #{e.message}") if defined?(Legion::Logging)
        nil
      end

      def merge_tick_data!(advisory, tick_result)
        return unless tick_result && tick_result[:results]

        results = tick_result[:results]
        apply_tool_hints!(advisory, results)
        apply_suppress!(advisory, results)
        advisory[:routing_hint] = results.dig(:post_tick_reflection, :routing_preference)
        advisory[:context_window] = results.dig(:memory_retrieval, :cross_conversation)
      end

      def apply_tool_hints!(advisory, results)
        predictions = results.dig(:prediction_engine, :predictions)
        return unless predictions

        tools = predictions.select { |p| p[:confidence] >= 0.6 }.map { |p| p[:tool] }
        advisory[:tool_hint] = tools.empty? ? nil : tools
      end

      def apply_suppress!(advisory, results)
        suppressed = results.dig(:sensory_processing, :suppressed)
        return unless suppressed

        arr = Array(suppressed)
        advisory[:suppress] = arr.empty? ? nil : arr
      end

      def merge_observer_data!(advisory, caller)
        identity = caller&.dig(:requested_by, :identity)
        return unless identity

        learned = AuditObserver.instance.learned_data_for(identity)
        advisory[:routing_hint] ||= learned[:routing_preference] if learned[:routing_preference]
        advisory[:tool_hint] ||= learned[:tool_predictions].keys.first(5) if learned[:tool_predictions]&.any?
      end

      private_class_method :merge_tick_data!, :apply_tool_hints!, :apply_suppress!, :merge_observer_data!
    end
  end
end
