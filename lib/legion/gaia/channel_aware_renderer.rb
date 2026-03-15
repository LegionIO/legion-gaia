# frozen_string_literal: true

module Legion
  module Gaia
    class ChannelAwareRenderer
      DEFAULTS = {
        cli: { max_length: nil, detail_level: :full },
        teams_desktop: { max_length: 4000, detail_level: :moderate },
        teams_mobile: { max_length: 500, detail_level: :concise },
        slack: { max_length: 3000, detail_level: :moderate },
        voice: { max_length: 200, detail_level: :terse }
      }.freeze

      def initialize(settings: {})
        @settings = settings
      end

      def render(output_frame)
        profile = resolve_profile(output_frame)
        max_length = profile[:max_length]

        return output_frame unless max_length

        content = output_frame.content.to_s
        return output_frame if content.length <= max_length

        truncate_frame(output_frame, content, max_length)
      end

      private

      def truncate_frame(output_frame, content, max_length)
        should_suggest = suggest_switch?(output_frame, content.length)
        suggestion = should_suggest ? transition_suggestion(output_frame) : nil
        suffix = suggestion ? "\n\n#{suggestion}" : ''
        truncated_content = content[0, max_length - suffix.length] + suffix

        hints = output_frame.channel_hints.merge(
          truncated: true, original_length: content.length,
          suggest_channel_switch: should_suggest, transition_suggestion: suggestion
        )

        OutputFrame.new(
          content: truncated_content, channel_id: output_frame.channel_id,
          id: output_frame.id, in_reply_to: output_frame.in_reply_to,
          content_type: output_frame.content_type,
          session_continuity_id: output_frame.session_continuity_id,
          channel_hints: hints, metadata: output_frame.metadata,
          created_at: output_frame.created_at
        )
      end

      def resolve_profile(output_frame)
        channel_id = output_frame.channel_id
        device = output_frame.metadata[:device_context]

        profile_key = if device == :mobile
                        :"#{channel_id}_mobile"
                      elsif device == :desktop
                        :"#{channel_id}_desktop"
                      else
                        channel_id
                      end

        DEFAULTS[profile_key] || DEFAULTS[channel_id] || DEFAULTS[:cli]
      end

      def suggest_switch?(output_frame, original_length)
        return false if output_frame.channel_id == :cli

        mobile_max = @settings.dig(:output, :mobile_max_length) || 500
        suggest = @settings.dig(:output, :suggest_channel_switch)
        suggest != false && original_length > mobile_max
      end

      def transition_suggestion(output_frame)
        richer = richer_channel(output_frame.channel_id)
        return nil unless richer

        "(Full response available on #{richer} - content was truncated for this channel)"
      end

      def richer_channel(current)
        richness = { voice: :slack, slack: :cli, teams: :cli }
        richness[current]
      end
    end
  end
end
