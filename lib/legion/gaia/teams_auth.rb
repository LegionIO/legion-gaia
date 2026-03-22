# frozen_string_literal: true

module Legion
  module Gaia
    module TeamsAuth
      private

      def check_teams_auth
        return unless teams_channel_enabled?
        return if teams_authenticated?
        return if teams_nudge_sent?

        Proactive.send_message(
          content: 'Teams is configured but not connected. Run `legion auth teams` when you\'re ready.',
          channel_id: :cli,
          content_type: :text
        )
        @teams_nudge_sent = true
      rescue StandardError => e
        Legion::Logging.warn("TeamsAuth check_teams_auth failed: #{e.message}") if defined?(Legion::Logging)
        nil
      end

      def teams_nudge_sent?
        @teams_nudge_sent == true
      end

      def teams_channel_enabled?
        s = settings
        return false unless s

        s.dig(:channels, :teams, :enabled) == true
      end

      def teams_authenticated?
        return false unless defined?(Legion::Extensions::MicrosoftTeams::Helpers::TokenCache)

        Legion::Extensions::MicrosoftTeams::Helpers::TokenCache.new.authenticated?
      rescue StandardError => e
        Legion::Logging.warn("TeamsAuth teams_authenticated? failed: #{e.message}") if defined?(Legion::Logging)
        false
      end
    end
  end
end
