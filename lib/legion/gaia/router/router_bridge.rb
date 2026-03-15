# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      class RouterBridge
        attr_reader :worker_routing, :channel_registry, :started

        def initialize(channel_registry:, worker_routing: nil, allowed_worker_ids: [])
          @channel_registry = channel_registry
          @worker_routing = worker_routing || WorkerRouting.new(allowed_worker_ids: allowed_worker_ids)
          @started = false
        end

        def start
          @started = true
        end

        def stop
          @started = false
        end

        def started?
          @started == true
        end

        def route_inbound(input_frame)
          return { routed: false, reason: :not_started } unless started?

          identity = extract_identity(input_frame)
          worker_id = @worker_routing.resolve_worker_id(identity)
          worker_id ||= @worker_routing.resolve_from_db(identity) if identity

          return offline_response(input_frame) unless worker_id

          publish_input_frame(input_frame, worker_id: worker_id)
        end

        def route_outbound(payload)
          return { delivered: false, reason: :not_started } unless started?

          frame = reconstruct_output_frame(payload)
          return { delivered: false, reason: :invalid_frame } unless frame

          adapter = @channel_registry.adapter_for(frame.channel_id)
          return { delivered: false, reason: :no_adapter, channel_id: frame.channel_id } unless adapter

          rendered = adapter.translate_outbound(frame)
          deliver_result = deliver_output(adapter, rendered, frame)
          { delivered: true, channel_id: frame.channel_id, frame_id: frame.id }.merge(deliver_result)
        end

        private

        def extract_identity(input_frame)
          input_frame.auth_context[:aad_object_id] ||
            input_frame.auth_context[:identity] ||
            input_frame.auth_context[:user_id]
        end

        def publish_input_frame(input_frame, worker_id:)
          return mock_publish(input_frame, worker_id) unless transport_available?

          Transport::Messages::InputFrameMessage.new(
            frame: input_frame,
            worker_id: worker_id
          ).publish

          { routed: true, worker_id: worker_id, frame_id: input_frame.id }
        end

        def mock_publish(input_frame, worker_id)
          { routed: true, worker_id: worker_id, frame_id: input_frame.id, transport: :mock }
        end

        def offline_response(input_frame)
          {
            routed: false,
            reason: :worker_not_found,
            identity: extract_identity(input_frame),
            frame_id: input_frame.id
          }
        end

        def reconstruct_output_frame(payload)
          OutputFrame.new(
            id: payload[:id],
            content: payload[:content],
            content_type: payload[:content_type]&.to_sym || :text,
            channel_id: payload[:channel_id]&.to_sym,
            in_reply_to: payload[:in_reply_to],
            session_continuity_id: payload[:session_continuity_id],
            channel_hints: payload[:channel_hints] || {},
            metadata: payload[:metadata] || {}
          )
        rescue StandardError
          nil
        end

        def deliver_output(adapter, rendered, frame)
          conversation_id = frame.metadata[:conversation_id]
          if adapter.respond_to?(:deliver) && conversation_id
            result = adapter.deliver(rendered, conversation_id: conversation_id)
            result.is_a?(Hash) ? result : { raw: result }
          elsif adapter.respond_to?(:deliver)
            result = adapter.deliver(rendered)
            result.is_a?(Hash) ? result : { raw: result }
          else
            { error: :adapter_cannot_deliver }
          end
        end

        def transport_available?
          defined?(Legion::Transport::Connection) && Legion::Transport::Connection.respond_to?(:session)
        end
      end
    end
  end
end
