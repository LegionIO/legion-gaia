# frozen_string_literal: true

module Legion
  module Gaia
    class ChannelRegistry
      def initialize
        @adapters = {}
        @mutex = Mutex.new
      end

      def register(adapter)
        @mutex.synchronize do
          @adapters[adapter.channel_id] = adapter
        end
      end

      def unregister(channel_id)
        @mutex.synchronize do
          adapter = @adapters.delete(channel_id)
          adapter&.stop
          adapter
        end
      end

      def adapter_for(channel_id)
        @mutex.synchronize { @adapters[channel_id] }
      end

      def active_channels
        @mutex.synchronize { @adapters.keys }
      end

      def active_adapters
        @mutex.synchronize { @adapters.values.select(&:started?) }
      end

      def size
        @mutex.synchronize { @adapters.size }
      end

      def deliver(output_frame)
        adapter = adapter_for(output_frame.channel_id)
        return { delivered: false, reason: :no_adapter } unless adapter
        return { delivered: false, reason: :adapter_stopped } unless adapter.started?

        rendered = adapter.translate_outbound(output_frame)
        adapter.deliver(rendered)
        { delivered: true, channel_id: output_frame.channel_id }
      end

      def start_all
        @mutex.synchronize { @adapters.each_value(&:start) }
      end

      def stop_all
        @mutex.synchronize { @adapters.each_value(&:stop) }
      end
    end
  end
end
