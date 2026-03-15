# frozen_string_literal: true

module Legion
  module Gaia
    class OutputRouter
      attr_reader :channel_registry, :renderer, :notification_gate

      def initialize(channel_registry:, renderer: nil, notification_gate: nil)
        @channel_registry = channel_registry
        @renderer = renderer
        @notification_gate = notification_gate
      end

      def route(output_frame)
        if @notification_gate
          decision = @notification_gate.evaluate(output_frame)
          if decision == :delay
            @notification_gate.enqueue(output_frame)
            return { delivered: false, reason: :delayed, pending: @notification_gate.pending_count }
          end
        end

        frame = render(output_frame)
        channel_registry.deliver(frame)
      end

      def process_delayed
        return [] unless @notification_gate

        frames = @notification_gate.process_delayed
        frames.map { |frame| channel_registry.deliver(frame) }
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
