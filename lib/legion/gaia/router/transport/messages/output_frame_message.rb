# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Messages
          class OutputFrameMessage < Legion::Transport::Message
            def exchange
              Exchanges::Gaia
            end

            def routing_key
              'gaia.outbound'
            end

            def message
              frame = @options[:frame]
              return @options.except(:frame) unless frame

              {
                id: frame.id,
                in_reply_to: frame.in_reply_to,
                content: frame.content,
                content_type: frame.content_type,
                channel_id: frame.channel_id,
                session_continuity_id: frame.session_continuity_id,
                channel_hints: frame.channel_hints,
                metadata: frame.metadata,
                created_at: frame.created_at.to_s
              }
            end

            def type
              'output_frame'
            end
          end
        end
      end
    end
  end
end
