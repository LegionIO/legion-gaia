# frozen_string_literal: true

module Legion
  module Gaia
    class ChannelAdapter
      attr_reader :channel_id, :capabilities

      def initialize(channel_id:, capabilities: [])
        @channel_id = channel_id
        @capabilities = capabilities
        @started = false
      end

      def start
        @started = true
      end

      def stop
        @started = false
      end

      def started?
        @started
      end

      def translate_inbound(raw_input)
        raise NotImplementedError, "#{self.class}#translate_inbound must be implemented"
      end

      def translate_outbound(output_frame)
        raise NotImplementedError, "#{self.class}#translate_outbound must be implemented"
      end

      def deliver(output_frame)
        raise NotImplementedError, "#{self.class}#deliver must be implemented"
      end

      def supports?(capability)
        capabilities.include?(capability)
      end
    end
  end
end
