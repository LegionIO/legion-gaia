# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'
require 'legion/gaia/response_attribution/journal'
require 'legion/gaia/response_attribution/receipts'

module Legion
  module Gaia
    # Proposals are not receipts. Learning is permitted only after a durable claim;
    # an interrupted claim is uncertain and must never replay its external effects.
    module ResponseAttribution
      extend Legion::Logging::Helper
      extend Journal
      extend Receipts

      TAGS = %w[gaia response-attribution].freeze
      ID_FIELDS = %i[behavioral_synapse_ids trace_ids adjustment_ids].freeze
      DELIVERED_OUTCOMES = %w[returned sent acknowledged].freeze
      MAX_PROPOSALS_PER_IDENTITY = 128

      @mutex = Mutex.new
      @states = {}
      @revision = 0
      @clean_revision = 0
      @hydration_failed = false
      # Bounded read index over the durable receipt journal, rebuilt on hydration.
      @correction_receipts = {}

      module_function

      def register_advisory(advisory_id:, identity:, conversation_id:, selected:, exchange_id: nil)
        return { registered: false, reason: :missing_identity } if identity.to_s.empty?
        return { registered: false, reason: :hydration_failed } if @mutex.synchronize { @hydration_failed }
        return { registered: false, reason: :invalid_advisory } if advisory_id.to_s.empty? || !selected.is_a?(Hash)
        if Legion::Gaia::BondRegistry.blocked?(identity: identity)
          return { registered: false,
                   reason: :identity_blocked }
        end

        @mutex.synchronize do
          state = state_for(identity: identity)
          return { registered: false, reason: :identity_erased } if state[:erased]
          if state[:receipts].key?(advisory_id.to_s) || state[:proposals].key?(advisory_id.to_s)
            return { registered: false, reason: :duplicate_advisory }
          end

          proposals = state[:proposals]
          proposals.shift while proposals.size >= MAX_PROPOSALS_PER_IDENTITY
          proposals[advisory_id.to_s] = {
            advisory_id: advisory_id.to_s, identity: identity.to_s,
            conversation_id: identifier(value: conversation_id), exchange_id: identifier(value: exchange_id),
            selected: copy(value: selected)
          }
          changed!(state: state)
          { registered: true, advisory_id: advisory_id.to_s }
        end
      end

      def record_applied(advisory_id:, identity:, applied:, store: nil)
        return { recorded: false, reason: :invalid_receipt } unless applied.is_a?(Hash) && !identity.to_s.empty?
        return { recorded: false, reason: :hydration_failed } if @mutex.synchronize { @hydration_failed }

        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          if Legion::Gaia::BondRegistry.blocked?(identity: identity)
            return { recorded: false,
                     reason: :identity_blocked }
          end

          result = @mutex.synchronize do
            prepare_receipt(advisory_id: advisory_id, identity: identity, applied: applied)
          end
          return result unless result[:recorded]

          durable = persist(store: store)
          result.merge(recorded: durable, durable: durable, reason: durable ? nil : :persistence_unavailable).compact
        end
      end

      def claim_feedback(identity:, observation:, store: nil)
        return { claimed: false, reason: :invalid_feedback } unless observation.is_a?(Hash) && !identity.to_s.empty?
        return { claimed: false, reason: :hydration_failed } if @mutex.synchronize { @hydration_failed }

        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          if Legion::Gaia::BondRegistry.blocked?(identity: identity)
            return { claimed: false,
                     reason: :identity_blocked }
          end

          result = @mutex.synchronize { prepare_claim(identity: identity, observation: observation) }
          return result unless result[:claimed]

          return { claimed: false, reason: :persistence_unavailable, uncertain: true } unless persist(store: store)

          @mutex.synchronize do
            receipt = @states[identity.to_s][:receipts][result[:receipt][:advisory_id]]
            if receipt[:feedback_evidence][:source] == 'explicit'
              index = (@correction_receipts[identity.to_s] ||= [])
              index << receipt
              index.shift while index.size > 128
            end
          end

          result
        end
      end

      def complete_feedback(identity:, advisory_id:, feedback_id:, store: nil)
        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          result = @mutex.synchronize do
            state = @states[identity.to_s]
            receipt = state&.dig(:receipts, advisory_id.to_s)
            unless receipt && receipt[:status] == 'claimed' && receipt[:feedback_id] == feedback_id.to_s
              next { completed: false, reason: :unmatched_claim }
            end

            # Keep correlation and explicit correction evidence; drop the proposal.
            receipt[:status] = 'completed'
            receipt.delete(:selected)
            ID_FIELDS.each { |field| receipt.delete(field) }
            changed!(state: state)
            { completed: true, advisory_id: advisory_id.to_s }
          end
          return result unless result[:completed]

          durable = persist(store: store)
          result.merge(completed: durable, durable: durable, reason: durable ? nil : :persistence_unavailable).compact
        end
      end

      def erase_partner!(identity:, store: nil)
        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          @mutex.synchronize do
            state = state_for(identity: identity)
            state[:erased] = true
            state[:proposals].clear
            state[:receipts].clear
            @correction_receipts.delete(identity.to_s)
            changed!(state: state)
          end
          durable = persist(store: store)
          { erased: durable, durable: durable, identity: identity.to_s }
        end
      end

      def status_for(identity:)
        @mutex.synchronize do
          state = @states[identity.to_s]
          next { pending: 0, uncertain: 0, completed: 0 } unless state

          counts = state[:receipts].values.group_by { |receipt| receipt[:status] }
          { pending: Array(counts['pending']).size, uncertain: Array(counts['claimed']).size,
            completed: Array(counts['completed']).size, erased: state[:erased] == true }
        end
      end

      def corrections_for(identity:, conversation_id: nil)
        return [] if Legion::Gaia::BondRegistry.blocked?(identity: identity)

        @mutex.synchronize do
          next [] if @hydration_failed

          Array(@correction_receipts[identity.to_s]).reverse_each.filter_map do |receipt|
            evidence = receipt[:feedback_evidence]
            next if evidence[:conversation_id] && evidence[:conversation_id].to_s != conversation_id.to_s

            { trace_id: "feedback:#{receipt[:feedback_id]}", trace_type: :episodic,
              domain_tags: ['correction', "partner:#{identity}"], strength: 1.0,
              content_payload: copy(value: evidence) }
          end
        end
      end

      def copy(value:)
        case value
        when Hash then value.to_h { |key, child| [key, copy(value: child)] }
        when Array then value.map { |child| copy(value: child) }
        when String then value.dup
        else value
        end
      end
      private_class_method :copy
    end
  end
end
