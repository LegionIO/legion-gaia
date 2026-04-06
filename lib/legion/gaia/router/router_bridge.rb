# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Router
      class RouterBridge
        include Legion::Logging::Helper

        attr_reader :worker_routing, :channel_registry, :started

        def initialize(channel_registry:, worker_routing: nil, allowed_worker_ids: [])
          log.unknown "initialize(channel_registry: #{channel_registry}, " \
                      "worker_routing: #{worker_routing}, allowed_worker_ids: #{allowed_worker_ids}"
          @channel_registry = channel_registry
          @worker_routing = worker_routing || WorkerRouting.new(allowed_worker_ids: allowed_worker_ids)
          @started = false
        end

        def start
          @started = true
          log.info("RouterBridge started workers=#{@worker_routing.size}")
        end

        def stop
          @started = false
          log.info('RouterBridge stopped')
        end

        def started?
          @started == true
        end

        def route_inbound(input_frame)
          log.unknown "route_inbound(input_frame: #{input_frame})"
          return { routed: false, reason: :not_started } unless started?

          identity = extract_identity(input_frame)
          worker_id = @worker_routing.resolve_worker_id(identity)
          worker_id ||= @worker_routing.resolve_from_db(identity) if identity

          return offline_response(input_frame) unless worker_id

          log.info("RouterBridge routing inbound frame_id=#{input_frame.id} worker_id=#{worker_id}")
          publish_input_frame(input_frame, worker_id: worker_id)
        end

        def route_outbound(payload)
          log.unknown "route_outbound(payload: #{payload})"
          return { delivered: false, reason: :not_started } unless started?

          frame = reconstruct_output_frame(payload)
          return { delivered: false, reason: :invalid_frame } unless frame

          adapter = @channel_registry.adapter_for(frame.channel_id)
          unless adapter
            log.error(
              'RouterBridge route_outbound failed ' \
              "frame_id=#{frame.id} channel_id=#{frame.channel_id} error=no_adapter"
            )
            return { delivered: false, reason: :no_adapter, channel_id: frame.channel_id }
          end

          rendered = adapter.translate_outbound(frame)
          deliver_result = normalize_delivery_result(
            deliver_output(adapter, rendered, frame),
            channel_id: frame.channel_id,
            frame_id: frame.id
          )
          if deliver_result[:delivered] == false || deliver_result[:error]
            log.error(
              'RouterBridge route_outbound failed ' \
              "frame_id=#{frame.id} channel_id=#{frame.channel_id} " \
              "error=#{deliver_result[:error] || deliver_result[:reason]}"
            )
          else
            log.info("RouterBridge routed outbound frame_id=#{frame.id} channel_id=#{frame.channel_id}")
          end
          deliver_result
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

          log.debug("RouterBridge published inbound frame_id=#{input_frame.id} worker_id=#{worker_id}")
          { routed: true, worker_id: worker_id, frame_id: input_frame.id }
        end

        def mock_publish(input_frame, worker_id)
          log.debug("RouterBridge mock-published frame_id=#{input_frame.id} worker_id=#{worker_id}")
          { routed: true, worker_id: worker_id, frame_id: input_frame.id, transport: :mock }
        end

        def offline_response(input_frame)
          identity = extract_identity(input_frame)
          log.warn("RouterBridge could not route inbound frame_id=#{input_frame.id} identity=#{identity}")
          {
            routed: false,
            reason: :worker_not_found,
            identity: identity,
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
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.router.router_bridge.reconstruct_output_frame')
          nil
        end

        def deliver_output(adapter, rendered, frame)
          conversation_id = frame.metadata[:conversation_id]
          if adapter.respond_to?(:deliver) && conversation_id
            adapter.deliver(rendered, conversation_id: conversation_id)
          elsif adapter.respond_to?(:deliver)
            adapter.deliver(rendered)
          else
            { error: :adapter_cannot_deliver }
          end
        end

        def normalize_delivery_result(result, channel_id:, frame_id:)
          if result == false
            return {
              delivered: false,
              reason: :adapter_returned_false,
              channel_id: channel_id,
              frame_id: frame_id
            }
          end

          return { delivered: true, channel_id: channel_id, frame_id: frame_id, raw: result } unless result.is_a?(Hash)

          normalized = result.dup
          normalized[:channel_id] ||= channel_id
          normalized[:frame_id] ||= frame_id
          normalized[:delivered] = false if normalized[:error] && !normalized.key?(:delivered)
          normalized[:delivered] = true unless normalized.key?(:delivered)
          normalized
        end

        def transport_available?
          defined?(Legion::Transport::Connection) && Legion::Transport::Connection.respond_to?(:session)
        end
      end
    end
  end
end
