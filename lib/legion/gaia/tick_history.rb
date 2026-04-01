# frozen_string_literal: true

module Legion
  module Gaia
    class TickHistory
      MAX_ENTRIES = 200

      def initialize
        @entries = []
        @mutex = Mutex.new
      end

      def record(tick_result)
        return unless tick_result.is_a?(Hash) && tick_result[:results].is_a?(Hash)

        timestamp = Time.now.utc.iso8601
        new_events = tick_result[:results].filter_map do |phase_name, phase_data|
          next unless phase_data.is_a?(Hash)

          {
            timestamp: timestamp,
            phase: phase_name.to_s,
            duration_ms: phase_data[:elapsed_ms],
            status: phase_data[:status]
          }
        end

        @mutex.synchronize do
          @entries.concat(new_events)
          @entries.shift(@entries.size - MAX_ENTRIES) if @entries.size > MAX_ENTRIES
        end
      end

      def recent(limit: 50)
        @mutex.synchronize do
          @entries.last(limit).dup
        end
      end

      def size
        @mutex.synchronize { @entries.size }
      end
    end
  end
end
