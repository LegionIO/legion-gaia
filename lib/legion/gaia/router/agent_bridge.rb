# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Router
      class AgentBridge
        include Legion::Logging::Helper

        attr_reader :worker_id, :started

        def initialize(worker_id:)
          @worker_id = worker_id
          @started = false
        end

        def start
          @started = true
          subscribe_inbound if transport_available?
          log.info("AgentBridge started worker_id=#{@worker_id}")
        end

        def stop
          @consumer&.cancel if @consumer.respond_to?(:cancel)
          @started = false
          log.info("AgentBridge stopped worker_id=#{@worker_id}")
        end

        def started?
          @started == true
        end

        def publish_output(output_frame)
          return { published: false, reason: :not_started } unless started?

          if transport_available?
            Transport::Messages::OutputFrameMessage.new(frame: output_frame).publish
            log.info("AgentBridge published output frame_id=#{output_frame.id} worker_id=#{@worker_id}")
            { published: true, frame_id: output_frame.id }
          else
            log.error(
              'AgentBridge publish failed ' \
              "frame_id=#{output_frame.id} worker_id=#{@worker_id} error=no_transport"
            )
            { published: false, reason: :no_transport, frame_id: output_frame.id }
          end
        end

        def ingest_from_payload(payload)
          frame = reconstruct_input_frame(payload)
          return { ingested: false, reason: :invalid_frame } unless frame

          if Legion::Gaia.respond_to?(:ingest) && Legion::Gaia.started?
            log.debug("AgentBridge ingesting frame_id=#{frame.id} worker_id=#{@worker_id}")
            Legion::Gaia.ingest(frame)
          else
            log.error("AgentBridge ingest failed frame_id=#{frame.id} worker_id=#{@worker_id} error=gaia_not_started")
            { ingested: false, reason: :gaia_not_started }
          end
        end

        private

        def subscribe_inbound
          queue = Transport::Queues::Inbound.new(worker_id: @worker_id)
          @consumer = queue.subscribe(manual_ack: true, block: false) do |delivery_info, _metadata, payload|
            message = decode_payload(payload)
            ingest_from_payload(message) if message
            queue.acknowledge(delivery_info.delivery_tag)
          rescue StandardError => e
            handle_exception(e, level: :error, operation: 'gaia.router.agent_bridge.subscribe_inbound',
                                worker_id: @worker_id)
            queue.reject(delivery_info.delivery_tag)
          end
        end

        def reconstruct_input_frame(payload)
          InputFrame.new(
            id: payload[:id],
            content: payload[:content],
            content_type: payload[:content_type]&.to_sym || :text,
            channel_id: payload[:channel_id]&.to_sym,
            channel_capabilities: payload[:channel_capabilities] || [],
            device_context: payload[:device_context] || {},
            session_continuity_id: payload[:session_continuity_id],
            auth_context: payload[:auth_context] || {},
            metadata: payload[:metadata] || {},
            principal_id: payload[:principal_id]
          )
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.router.agent_bridge.reconstruct_input_frame',
                              worker_id: @worker_id)
          nil
        end

        def decode_payload(raw)
          parsed = Legion::JSON.load(raw)
          parsed.is_a?(Hash) ? parsed : nil
        rescue StandardError => e
          handle_exception(e, level: :warn, operation: 'gaia.router.agent_bridge.decode_payload',
                              worker_id: @worker_id)
          nil
        end

        def transport_available?
          defined?(Legion::Transport::Connection) && Legion::Transport::Connection.respond_to?(:session)
        end
      end
    end
  end
end
