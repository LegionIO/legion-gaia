# frozen_string_literal: true

module Legion
  module Gaia
    class ChannelAdapter
      attr_reader :channel_id, :capabilities

      @adapter_classes = []

      class << self
        attr_reader :adapter_classes

        def register_adapter(klass)
          @adapter_classes << klass unless @adapter_classes.include?(klass)
        end

        def inherited(subclass)
          super
          register_adapter(subclass)
        end
      end

      def initialize(channel_id:, capabilities: [])
        @channel_id = channel_id
        @capabilities = capabilities
        @started = false
      end

      def self.from_settings(_settings)
        nil
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

      DIRECT_ADDRESS_PATTERN = /\bgaia\b/i

      def supports?(capability)
        capabilities.include?(capability)
      end

      private

      def direct_address?(content)
        content.to_s.match?(DIRECT_ADDRESS_PATTERN)
      end
    end
  end
end
