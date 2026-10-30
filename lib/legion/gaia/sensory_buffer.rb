# frozen_string_literal: true

module Legion
  module Gaia
    class SensoryBuffer
      MAX_BUFFER_SIZE = 1000

      def initialize
        @mutex = Mutex.new
        @buffer = []
      end

      def push(signal)
        @mutex.synchronize do
          @buffer.shift if @buffer.size >= MAX_BUFFER_SIZE
          @buffer << normalize_signal(signal)
        end
      end

      def drain
        @mutex.synchronize do
          signals = @buffer.dup
          @buffer.clear
          signals
        end
      end

      # One scope per heartbeat keeps both private context and the tick budget bounded.
      def drain_scope
        @mutex.synchronize do
          return [] if @buffer.empty?

          first = @buffer.first
          identity = first[:identity] || first[:principal_id]
          conversation_id = first[:conversation_id] || first[:session_continuity_id]
          selected, remaining = @buffer.partition do |signal|
            (signal[:identity] || signal[:principal_id]) == identity &&
              (signal[:conversation_id] || signal[:session_continuity_id]) == conversation_id
          end
          @buffer = remaining
          selected
        end
      end

      def erase_identity(identity:)
        @mutex.synchronize do
          @buffer.reject! { |signal| (signal[:identity] || signal[:principal_id]).to_s == identity.to_s }
        end
      end

      def size
        @mutex.synchronize { @buffer.size }
      end

      def empty?
        @mutex.synchronize { @buffer.empty? }
      end

      private

      def normalize_signal(signal)
        signal = { value: signal } unless signal.is_a?(Hash)
        signal[:received_at] ||= Time.now.utc
        signal[:salience] ||= 0.0
        signal[:source_type] ||= :ambient
        signal
      end
    end
  end
end
