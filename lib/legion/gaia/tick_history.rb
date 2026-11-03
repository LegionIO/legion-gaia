# frozen_string_literal: true

require 'time'

module Legion
  module Gaia
    class TickHistory
      extend Legion::Logging::Helper

      MAX_ENTRIES = 200

      def initialize
        @entries = []
        @mutex = Mutex.new
      end

      def record(tick_result, identity: nil, conversation_id: nil, exchange_id: nil)
        return unless tick_result.is_a?(Hash) && tick_result[:results].is_a?(Hash)

        scope = { identity: identity, conversation_id: conversation_id, exchange_id: exchange_id }
                .transform_values { |value| value.nil? ? nil : value.to_s.dup.freeze }
        scope[:timestamp] = Time.now.utc.iso8601(3).freeze
        new_events = complete_phase_results(tick_result: tick_result).filter_map do |phase, data|
          phase_event(phase: phase, data: data, scope: scope)
        end
        @mutex.synchronize do
          @entries.concat(new_events)
          @entries.shift(@entries.size - MAX_ENTRIES) if @entries.size > MAX_ENTRIES
        end
      end

      def recent(limit: 50, identity: nil, conversation_id: nil)
        @mutex.synchronize do
          entries = @entries
          entries = entries.select { |entry| entry[:identity] == identity.to_s } unless identity.nil?
          unless conversation_id.nil?
            entries = entries.select do |entry|
              entry[:conversation_id] == conversation_id.to_s
            end
          end
          entries.last(limit.to_i.clamp(0, MAX_ENTRIES)).map(&:dup)
        end
      end

      def size
        @mutex.synchronize { @entries.size }
      end

      private

      def complete_phase_results(tick_result:)
        results = tick_result[:results].dup
        Array(tick_result[:phases_skipped]).each do |phase|
          results[phase] ||= { status: :budget_skipped, reason: :tick_budget_exhausted, meaningful: false }
        end
        (Array(tick_result[:phases_scheduled]) - results.keys).each do |phase|
          results[phase] = { status: :unavailable, reason: :missing_phase_result, meaningful: false }
        end
        results
      end

      def phase_event(phase:, data:, scope:)
        data = PhaseWiring.normalize_phase_result(data)
        return unless data.is_a?(Hash)

        scope.merge(
          phase: phase.to_s.freeze,
          duration_ms: data[:elapsed_ms] || data[:duration_ms] || 0.0,
          status: PhaseWiring.phase_status(data),
          meaningful: PhaseWiring.meaningful_result?(data),
          reason: data[:reason],
          handlers: Array(data[:handlers]).map do |handler|
            { provider: handler[:provider], status: PhaseWiring.phase_status(handler),
              reason: handler[:reason] }.freeze
          end.freeze
        ).freeze
      end
    end
  end
end
