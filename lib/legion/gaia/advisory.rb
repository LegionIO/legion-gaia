# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Advisory
      extend Legion::Logging::Helper

      module_function

      # Fast in-memory advisory. NEVER makes LLM calls.
      # Returns Hash with optional keys: system_prompt, routing_hint,
      # context_window, tool_hint, suppress, valence
      def advise(caller:, conversation_id: nil, messages: nil)
        log.debug "advise(caller: #{caller}, conversation_id: #{conversation_id}, messages: #{messages}) "
        return nil unless Gaia.started?

        advisory = {}
        advisory[:valence] = Gaia.last_valences if Gaia.last_valences
        merge_tick_data!(advisory, Gaia.registry&.tick_host&.last_tick_result)
        merge_observer_data!(advisory, caller)
        result = advisory.compact
        if result.any?
          log.info("GAIA advisory generated conversation_id=#{conversation_id} keys=#{result.keys.join(',')}")
        end
        result
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.advisory.advise', conversation_id: conversation_id)
        {}
      end

      def merge_tick_data!(advisory, tick_result)
        log.debug "merge_tick_data!(#{advisory.inspect}, #{tick_result})"
        return unless tick_result && tick_result[:results]

        results = tick_result[:results]
        apply_tool_hints!(advisory, results)
        apply_suppress!(advisory, results)
        advisory[:routing_hint] = normalize_routing_hint(results.dig(:post_tick_reflection, :routing_preference))
        advisory[:context_window] = results.dig(:memory_retrieval, :cross_conversation)
      end

      def apply_tool_hints!(advisory, results)
        predictions = results.dig(:prediction_engine, :predictions)
        return unless predictions

        tools = predictions.filter_map do |prediction|
          confidence = value_for(prediction, :confidence).to_f
          tool = value_for(prediction, :tool)
          tool if confidence >= 0.6 && tool
        end
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
        advisory[:routing_hint] ||= normalize_routing_hint(learned[:routing_preference]) if learned[:routing_preference]
        advisory[:tool_hint] ||= learned[:tool_predictions].keys.first(5) if learned[:tool_predictions]&.any?
      end

      def normalize_routing_hint(value)
        return nil if value.nil?

        if value.is_a?(Hash)
          provider = value_for(value, :provider)
          model = value_for(value, :model)
          return nil if provider.to_s.empty? && model.to_s.empty?

          return { provider: provider&.to_s, model: model&.to_s }
        end

        { provider: value.to_s, model: nil }
      end

      def value_for(hash, key)
        return nil unless hash.respond_to?(:key?)

        string_key = key.to_s
        return hash[key] if hash.key?(key)
        return hash[string_key] if hash.key?(string_key)

        nil
      end

      private_class_method :merge_tick_data!, :apply_tool_hints!, :apply_suppress!, :merge_observer_data!,
                           :normalize_routing_hint, :value_for
    end
  end
end
