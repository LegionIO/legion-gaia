# frozen_string_literal: true

module Legion
  module Gaia
    class NotificationGate
      class DelayQueue
        attr_reader :max_size, :max_delay

        def initialize(max_size: 100, max_delay: 14_400)
          @max_size = max_size
          @max_delay = max_delay
          @entries = []
          @mutex = Mutex.new
        end

        def enqueue(frame)
          @mutex.synchronize do
            evicted = nil
            evicted = @entries.shift if @entries.size >= @max_size
            @entries << { frame: frame, queued_at: Time.now.utc, retry_count: 0 }
            evicted
          end
        end

        def size
          @mutex.synchronize { @entries.size }
        end

        def pending
          @mutex.synchronize { @entries.dup }
        end

        def drain_expired
          @mutex.synchronize do
            cutoff = Time.now.utc - @max_delay
            expired, @entries = @entries.partition { |e| e[:queued_at] < cutoff }
            expired
          end
        end

        def flush
          @mutex.synchronize do
            all = @entries.dup
            @entries.clear
            all
          end
        end

        def clear
          @mutex.synchronize { @entries.clear }
        end
      end
    end
  end
end
