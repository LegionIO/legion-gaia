# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module TeamsAuth
      include Legion::Logging::Helper

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
        log.info('TeamsAuth sent CLI nudge for Teams authentication')
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.teams_auth.check_teams_auth')
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
        handle_exception(e, level: :warn, operation: 'gaia.teams_auth.teams_authenticated')
        false
      end
    end
  end
end
