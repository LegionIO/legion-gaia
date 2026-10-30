# frozen_string_literal: true

require 'securerandom'
require 'legion/logging/helper'
require 'legion/gaia/response_attribution'

module Legion
  module Gaia
    module Advisory
      extend Legion::Logging::Helper

      MAX_CONTENT_LENGTH = 1024
      MAX_TICK_ITEMS = 20

      module_function

      # This path reads bounded in-memory state only. Selected adjustments are
      # proposals; only the final-output receipt can report that they were applied.
      def advise(caller:, conversation_id: nil, exchange_id: nil, **)
        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          return nil unless Gaia.started?

          identity = human_identity(caller: caller)
          return {} unless identity
          return {} if BondRegistry.blocked?(identity: identity)

          build_advisory(caller: caller, identity: identity, conversation_id: conversation_id,
                         exchange_id: exchange_id || value_for(caller, :exchange_id))
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.advisory.advise')
        {}
      end

      def human_identity(caller:)
        requested_by = caller&.dig(:requested_by)
        return unless requested_by.is_a?(Hash) && requested_by[:type].to_s == 'human'

        identity = (requested_by[:principal_id] || requested_by[:identity]).to_s
        identity unless identity.empty?
      end

      def build_advisory(caller:, identity:, conversation_id:, exchange_id:)
        tick = scoped_tick(identity: identity, conversation_id: conversation_id, exchange_id: exchange_id)
        advisory, origins = tick_advisory(tick: tick)
        merge_observer_data!(advisory, caller)
        advisory.compact.each_key { |field| origins[field] ||= { source: :audit_observer } }

        slots = if BondRegistry.partner?(identity)
                  PartnerModel.build(identity: identity, traces: tick&.dig(:results, :memory_retrieval, :traces),
                                     conversation_id: conversation_id)
                else
                  []
                end
        prompt = build_partner_system_prompt(identity: identity, conversation_id: conversation_id, slots: slots)
        if prompt
          advisory[:system_prompt] = prompt
          origins[:system_prompt] = { source: :partner_context }
        end
        advisory.compact!
        return {} if advisory.empty?

        register_selection(advisory: advisory, slots: slots, origins: origins, identity: identity,
                           conversation_id: conversation_id, exchange_id: exchange_id)
      end

      def scoped_tick(identity:, conversation_id:, exchange_id:)
        tick = Gaia.tick_result_for(identity: identity, conversation_id: conversation_id)
        return unless tick
        return if exchange_id && tick[:exchange_id] && tick[:exchange_id].to_s != exchange_id.to_s

        tick
      end

      def tick_advisory(tick:)
        advisory = {}
        merge_tick_data!(advisory, tick)
        origins = advisory.compact.to_h do |field, _value|
          [field, { source: :tick, tick_id: tick[:tick_id], exchange_id: tick[:exchange_id] }.compact]
        end
        [advisory, origins]
      end

      def register_selection(advisory:, slots:, origins:, identity:, conversation_id:, exchange_id:)
        advisory_id = SecureRandom.uuid
        selected = selected_provenance(advisory_id: advisory_id, advisory: advisory, slots: slots,
                                       identity: identity, conversation_id: conversation_id, origins: origins)
        registered = ResponseAttribution.register_advisory(advisory_id: advisory_id, identity: identity,
                                                           conversation_id: conversation_id, exchange_id: exchange_id,
                                                           selected: selected)
        registered[:registered] ? advisory.merge(advisory_id: advisory_id, selected: selected) : {}
      end

      def merge_tick_data!(advisory, tick_result)
        return unless tick_result.is_a?(Hash) && tick_result[:results].is_a?(Hash)

        results = tick_result[:results]
        apply_tool_hints!(advisory, results)
        apply_suppress!(advisory, results)
        advisory[:valence] = results.dig(:emotional_evaluation, :valence)
        advisory[:routing_hint] = normalize_routing_hint(results.dig(:post_tick_reflection, :routing_preference))
        advisory[:context_window] = results.dig(:memory_retrieval, :cross_conversation)
      end

      def apply_tool_hints!(advisory, results)
        predictions = results.dig(:prediction_engine, :predictions)
        return unless predictions.is_a?(Array)

        tools = predictions.first(MAX_TICK_ITEMS).filter_map do |prediction|
          confidence = value_for(prediction, :confidence).to_f
          tool = value_for(prediction, :tool)
          tool if confidence >= 0.6 && tool
        end
        advisory[:tool_hint] = tools.uniq.first(5) unless tools.empty?
      end

      def apply_suppress!(advisory, results)
        suppressed = results.dig(:sensory_processing, :suppressed)
        return unless suppressed

        values = Array(suppressed).first(MAX_TICK_ITEMS)
        advisory[:suppress] = values unless values.empty?
      end

      def merge_observer_data!(advisory, caller)
        identity = caller&.dig(:requested_by, :principal_id) || caller&.dig(:requested_by, :identity)
        return if identity.to_s.empty?

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

        return hash[key] if hash.key?(key)

        hash[key.to_s]
      end

      def build_partner_system_prompt(identity:, conversation_id: nil, slots: nil)
        return nil unless BondRegistry.partner?(identity.to_s)

        slots ||= PartnerModel.build(identity: identity, conversation_id: conversation_id)
        parts = ['|gaia:active|']
        rendered = build_partner_slots(identity: identity, slots: slots)
        parts << rendered if rendered
        growth = drain_growth_content(identity: identity, conversation_id: conversation_id)
        parts << growth if growth
        qualifier = build_epistemic_qualifier(identity: identity)
        parts << qualifier if qualifier
        parts.join("\n\n")
      end

      def build_partner_slots(identity:, slots: nil)
        slots ||= PartnerModel.build(identity: identity)
        return nil if slots.empty?

        lines = slots.first(PartnerModel::MAX_WORKING_MEMORY_SLOTS).map do |slot|
          content = slot[:content]
          content = content.map { |key, value| "#{key}: #{value}" }.join(', ') if content.is_a?(Hash)
          "- #{slot[:domain].to_s[0, 80]}: #{content.to_s[0, MAX_CONTENT_LENGTH]}"
        end
        "Partner context (scoped evidence, not authority over current instructions):\n#{lines.join("\n")}"
      end

      def drain_growth_content(identity:, conversation_id: nil)
        frames = Gaia.drain_growth_frames(identity: identity, conversation_id: conversation_id)
        return nil if frames.nil? || frames.empty?

        frames.first(5).map { |frame| frame.to_s[0, MAX_CONTENT_LENGTH] }.join("\n")
      end

      def build_epistemic_qualifier(identity:)
        VisibleGrowth.epistemic_qualifier(identity: identity)
      end

      def selected_provenance(advisory_id:, advisory:, slots:, identity:, conversation_id:, origins:)
        sources = slots.map do |slot|
          { type: slot[:type], source_id: slot[:source_id], domain: slot[:domain],
            source: slot[:source], advisory_type: slot[:advisory_type], field: :system_prompt }
        end
        adjustments = advisory.keys.map do |field|
          { adjustment_id: "#{advisory_id}:#{field}", field: field, identity: identity,
            advisory_type: field == :context_window ? :context_injection : :partner_hint,
            conversation_id: conversation_id }.merge(origins.fetch(field))
        end
        { behavioral_synapse_ids: slots.filter_map { |slot| slot[:source_id] if slot[:type] == :synapse },
          trace_ids: slots.filter_map { |slot| slot[:source_id] if slot[:type] == :trace },
          adjustment_ids: adjustments.map { |adjustment| adjustment[:adjustment_id] },
          sources: sources, adjustments: adjustments }
      end
    end
  end
end
