# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      class AgentBridge
        attr_reader :worker_id, :started

        def initialize(worker_id:)
          @worker_id = worker_id
          @started = false
        end

        def start
          @started = true
          subscribe_inbound if transport_available?
        end

        def stop
          @consumer&.cancel if @consumer.respond_to?(:cancel)
          @started = false
        end

        def started?
          @started == true
        end

        def publish_output(output_frame)
          return { published: false, reason: :not_started } unless started?

          if transport_available?
            Transport::Messages::OutputFrameMessage.new(frame: output_frame).publish
            { published: true, frame_id: output_frame.id }
          else
            { published: false, reason: :no_transport, frame_id: output_frame.id }
          end
        end

        def ingest_from_payload(payload)
          frame = reconstruct_input_frame(payload)
          return { ingested: false, reason: :invalid_frame } unless frame

          if Legion::Gaia.respond_to?(:ingest) && Legion::Gaia.started?
            Legion::Gaia.ingest(frame)
          else
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
            log_error("AgentBridge inbound error: #{e.message}")
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
            metadata: payload[:metadata] || {}
          )
        rescue StandardError
          nil
        end

        def decode_payload(raw)
          parsed = Legion::JSON.load(raw)
          parsed.is_a?(Hash) ? parsed : nil
        rescue StandardError
          nil
        end

        def transport_available?
          defined?(Legion::Transport::Connection) && Legion::Transport::Connection.respond_to?(:session)
        end

        def log_error(msg)
          Legion::Logging.error(msg) if Legion.const_defined?('Logging')
        end
      end
    end
  end
end
