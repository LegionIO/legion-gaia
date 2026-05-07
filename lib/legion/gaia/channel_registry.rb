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
        return { delivered: false, reason: :no_adapter, channel_id: output_frame.channel_id } unless adapter
        unless adapter.started?
          return { delivered: false, reason: :adapter_stopped, channel_id: output_frame.channel_id }
        end

        rendered = adapter.translate_outbound(output_frame)
        normalize_delivery_result(deliver_to_adapter(adapter, rendered, output_frame),
                                  channel_id: output_frame.channel_id)
      end

      def start_all
        @mutex.synchronize { @adapters.each_value(&:start) }
      end

      def stop_all
        @mutex.synchronize { @adapters.each_value(&:stop) }
      end

      private

      def deliver_to_adapter(adapter, rendered, output_frame)
        conversation_id = output_frame.metadata[:conversation_id]
        if conversation_id && deliver_accepts_conversation_id?(adapter)
          adapter.deliver(rendered, conversation_id: conversation_id)
        else
          adapter.deliver(rendered)
        end
      end

      def deliver_accepts_conversation_id?(adapter)
        parameters = adapter.class.instance_method(:deliver).parameters
        parameters.any? do |type, name|
          %i[key keyreq].include?(type) && name == :conversation_id
        end
      rescue StandardError
        adapter.method(:deliver).parameters.any? do |type, name|
          %i[key keyreq].include?(type) && name == :conversation_id
        end
      end

      def normalize_delivery_result(result, channel_id:)
        return { delivered: false, reason: :adapter_returned_false, channel_id: channel_id } if result == false
        return { delivered: true, channel_id: channel_id } unless result.is_a?(Hash)

        normalized = result.dup
        normalized[:channel_id] ||= channel_id
        normalized[:delivered] = false if normalized[:error] && !normalized.key?(:delivered)
        normalized[:delivered] = true unless normalized.key?(:delivered)
        normalized
      end
    end
  end
end
