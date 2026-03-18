# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Messages
          class InputFrameMessage < Legion::Transport::Message
            def exchange
              Legion::Transport::Exchanges::Agent
            end

            def routing_key
              worker_id = @options[:worker_id] || 'default'
              "agent.#{worker_id}"
            end

            def message
              frame = @options[:frame]
              return @options.except(:worker_id, :frame) unless frame

              {
                id: frame.id,
                content: frame.content,
                content_type: frame.content_type,
                channel_id: frame.channel_id,
                channel_capabilities: frame.channel_capabilities,
                device_context: frame.device_context,
                session_continuity_id: frame.session_continuity_id,
                auth_context: frame.auth_context,
                metadata: frame.metadata,
                received_at: frame.received_at.to_s
              }
            end

            def type
              'input_frame'
            end
          end
        end
      end
    end
  end
end
