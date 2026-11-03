# frozen_string_literal: true

module Legion
  module Gaia
    module ResponseAttribution
      # These transitions run under the owner's mutex; the owner acknowledges the journal write.
      module Receipts
        private

        def prepare_receipt(advisory_id:, identity:, applied:)
          state = @states[identity.to_s]
          id = advisory_id.to_s
          reason = receipt_rejection(state: state, advisory_id: id, applied: applied)
          return { recorded: false, reason: reason } if reason

          proposal = state[:proposals][id]
          ids = ID_FIELDS.to_h { |field| [field, Array(applied[field]).map(&:to_s).reject(&:empty?).uniq] }
          reason = applied_rejection(proposal: proposal, applied: applied, ids: ids)
          return { recorded: false, reason: reason } if reason

          receipt = delivered_receipt(proposal: proposal, applied: applied, ids: ids)
          state[:receipts][id] = receipt
          state[:proposals].delete(id)
          changed!(state: state)
          { recorded: true, advisory_id: id, receipt: copy(value: receipt) }
        end

        def receipt_rejection(state:, advisory_id:, applied:)
          return :identity_erased if state&.dig(:erased)
          return :duplicate_receipt if state&.dig(:receipts, advisory_id)

          proposal = state&.dig(:proposals, advisory_id)
          return :unknown_advisory unless proposal
          return :correlation_mismatch unless matching_scope?(proposal: proposal, applied: applied)

          nil
        end

        def applied_rejection(proposal:, applied:, ids:)
          return :missing_applied_ids if ids.values.all?(&:empty?)
          return :unselected_ids unless ids.all? do |field, values|
            (values - Array(proposal[:selected][field]).map(&:to_s)).empty?
          end
          unless DELIVERED_OUTCOMES.include?((applied[:delivery_status] || applied[:outcome]).to_s)
            return :not_delivered
          end

          nil
        end

        def delivered_receipt(proposal:, applied:, ids:)
          receipt = proposal.merge(ids).merge(
            status: 'pending', delivery_status: (applied[:delivery_status] || applied[:outcome]).to_s,
            conversation_id: identifier(value: applied[:conversation_id]) || proposal[:conversation_id],
            exchange_id: identifier(value: applied[:exchange_id]) || proposal[:exchange_id],
            response_id: identifier(value: applied[:response_id])
          )
          applied_ids = ids[:behavioral_synapse_ids] + ids[:trace_ids]
          domains = Array(proposal[:selected][:sources]).filter_map do |source|
            source[:domain].to_s if applied_ids.include?(source[:source_id].to_s) && source[:domain]
          end
          receipt[:domains] = domains.uniq
          receipt[:domain] = receipt[:domains].first if receipt[:domains].one?
          receipt
        end

        def prepare_claim(identity:, observation:)
          feedback_id = identifier(value: observation[:feedback_id])
          state = @states[identity.to_s]
          reason = feedback_rejection(identity: identity, observation: observation,
                                      feedback_id: feedback_id, state: state)
          return { claimed: false, reason: reason } if reason

          match = feedback_match(receipts: state[:receipts].values, observation: observation)
          return { claimed: false, reason: match[:reason] } if match[:reason]

          receipt = match[:receipt]
          receipt[:status] = 'claimed'
          receipt[:feedback_id] = feedback_id
          receipt[:feedback_evidence] = feedback_evidence(receipt: receipt, observation: observation)
          changed!(state: state)
          { claimed: true, receipt: copy(value: receipt), feedback_id: feedback_id }
        end

        def feedback_rejection(identity:, observation:, feedback_id:, state:)
          return :missing_feedback_id unless feedback_id
          return :identity_mismatch if observation[:identity] && observation[:identity].to_s != identity.to_s
          return :unmatched unless state && !state[:erased]
          return :duplicate_feedback if state[:receipts].values.any? { |receipt| receipt[:feedback_id] == feedback_id }

          nil
        end

        def feedback_match(receipts:, observation:)
          correlation = observation.slice(:advisory_id, :in_reply_to, :exchange_id, :conversation_id)
                                   .transform_values { |value| identifier(value: value) }.compact
          return { reason: :missing_correlation } if correlation.empty?

          # Completed tombstones still count toward ambiguity: delayed feedback cannot jump receipts.
          matching = receipts.select { |receipt| correlated?(receipt: receipt, correlation: correlation) }
          return { reason: :unmatched } if matching.empty?
          return { reason: :ambiguous } unless matching.one?

          receipt = matching.first
          return { reason: :uncertain } if receipt[:status] == 'claimed'
          return { reason: :completed } unless receipt[:status] == 'pending'

          { receipt: receipt }
        end

        def feedback_evidence(receipt:, observation:)
          constraint = corrected_constraint(observation: observation)
          explicit_negative = observation[:explicit_feedback].to_s == 'negative'
          {
            feedback_id: receipt[:feedback_id], content: observation[:content].to_s[0, 2048],
            conversation_id: receipt[:conversation_id], domain: observation[:domain] || receipt[:domain],
            corrected_constraint: copy(value: constraint),
            correction_type: explicit_negative ? 'explicit_negative_feedback' : 'explicit_correction',
            source: explicit_negative || constraint ? 'explicit' : 'unassigned',
            applied_synapse_ids: Array(receipt[:behavioral_synapse_ids]),
            applied_trace_ids: Array(receipt[:trace_ids]),
            blocked_domains: explicit_negative ? Array(receipt[:domains]) : []
          }
        end

        def corrected_constraint(observation:)
          constraint = observation[:corrected_constraint]
          return unless constraint.is_a?(String) || constraint.is_a?(Hash)
          return if constraint.empty? || Legion::JSON.dump(constraint).bytesize > 2048

          constraint
        end

        def correlated?(receipt:, correlation:)
          correlation.all? do |key, value|
            if key == :in_reply_to
              [receipt[:advisory_id], receipt[:exchange_id], receipt[:response_id]].include?(value)
            else
              receipt[key] == value
            end
          end
        end

        def matching_scope?(proposal:, applied:)
          %i[identity conversation_id exchange_id].all? do |key|
            expected = proposal[key]
            actual = identifier(value: applied[key])
            actual.nil? || expected.nil? || expected == actual
          end
        end

        def identifier(value:)
          value.to_s unless value.nil? || value.to_s.empty?
        end
      end
    end
  end
end
