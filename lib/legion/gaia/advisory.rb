# frozen_string_literal: true

module Legion
  module Gaia
    module Advisory
      module_function

      # Fast in-memory advisory. NEVER makes LLM calls.
      # Returns Hash with optional keys: system_prompt, routing_hint,
      # context_window, tool_hint, suppress, valence
      def advise(conversation_id:, messages:, caller:)
        return nil unless Gaia.started?

        tick_result = Gaia.registry&.tick_host&.last_tick_result
        valences = Gaia.last_valences

        advisory = {}
        advisory[:valence] = valences if valences

        if tick_result && tick_result[:results]
          results = tick_result[:results]

          # Tool predictions from inference engine
          if (predictions = results.dig(:prediction_engine, :predictions))
            advisory[:tool_hint] = predictions.select { |p| p[:confidence] >= 0.6 }
                                              .map { |p| p[:tool] }
            advisory[:tool_hint] = nil if advisory[:tool_hint]&.empty?
          end

          # Suppression hints from attention filtering
          if (suppressed = results.dig(:sensory_processing, :suppressed))
            advisory[:suppress] = Array(suppressed)
            advisory[:suppress] = nil if advisory[:suppress].empty?
          end

          # Routing hint from observed preferences (populated by observer)
          if (routing = results.dig(:post_tick_reflection, :routing_preference))
            advisory[:routing_hint] = routing
          end

          # Cross-conversation context from memory retrieval
          if (memory = results.dig(:memory_retrieval, :cross_conversation))
            advisory[:context_window] = memory
          end
        end

        # Learned data from audit observer
        identity = caller&.dig(:requested_by, :identity)
        if identity
          learned = AuditObserver.learned_data_for(identity)
          advisory[:routing_hint] ||= learned[:routing_preference] if learned[:routing_preference]
          if learned[:tool_predictions]&.any?
            advisory[:tool_hint] ||= learned[:tool_predictions].keys.first(5)
          end
        end

        advisory.compact
      rescue StandardError => e
        Legion::Logging.warn("GAIA advisory failed: #{e.message}") if defined?(Legion::Logging)
        nil
      end
    end
  end
end
