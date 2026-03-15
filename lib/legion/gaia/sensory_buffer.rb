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
