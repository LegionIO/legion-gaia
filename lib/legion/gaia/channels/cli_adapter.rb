# frozen_string_literal: true

module Legion
  module Gaia
    module Channels
      class CliAdapter < ChannelAdapter
        CAPABILITIES = %i[rich_text inline_code file_attachment syntax_highlighting].freeze

        def initialize
          super(channel_id: :cli, capabilities: CAPABILITIES)
          @output_buffer = []
        end

        def translate_inbound(raw_input)
          text = raw_input.is_a?(String) ? raw_input : raw_input.to_s

          InputFrame.new(
            content: text,
            channel_id: :cli,
            content_type: :text,
            channel_capabilities: CAPABILITIES,
            device_context: { platform: :desktop, input_method: :keyboard },
            metadata: { source_type: :human_direct, salience: 0.9 }
          )
        end

        def translate_outbound(output_frame)
          output_frame.content.to_s
        end

        def deliver(rendered_content)
          @output_buffer << rendered_content
          rendered_content
        end

        def drain_output
          output = @output_buffer.dup
          @output_buffer.clear
          output
        end

        def last_output
          @output_buffer.last
        end

        def output_buffer_size
          @output_buffer.size
        end
      end
    end
  end
end
