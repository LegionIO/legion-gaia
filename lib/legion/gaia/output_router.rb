# frozen_string_literal: true

module Legion
  module Gaia
    class OutputRouter
      attr_reader :channel_registry, :renderer

      def initialize(channel_registry:, renderer: nil)
        @channel_registry = channel_registry
        @renderer = renderer
      end

      def route(output_frame)
        frame = render(output_frame)
        channel_registry.deliver(frame)
      end

      def route_to(output_frame, channel_id:)
        adapted = OutputFrame.new(
          content: output_frame.content,
          channel_id: channel_id,
          id: output_frame.id,
          in_reply_to: output_frame.in_reply_to,
          content_type: output_frame.content_type,
          session_continuity_id: output_frame.session_continuity_id,
          channel_hints: output_frame.channel_hints,
          metadata: output_frame.metadata,
          created_at: output_frame.created_at
        )
        route(adapted)
      end

      private

      def render(output_frame)
        return output_frame unless @renderer

        @renderer.render(output_frame)
      end
    end
  end
end
