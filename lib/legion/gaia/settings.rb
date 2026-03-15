# frozen_string_literal: true

module Legion
  module Gaia
    module Settings
      module_function

      def default
        {
          connected: false,
          enabled: true,
          heartbeat_interval: 1,
          channels: default_channels,
          router: { mode: false, allowed_worker_ids: [] },
          session: { persistence: 'auto', ttl: 86_400 },
          output: { mobile_max_length: 500, suggest_channel_switch: true },
          notifications: default_notifications
        }
      end

      def default_channels
        {
          cli: { enabled: true },
          teams: { enabled: false },
          slack: { enabled: false }
        }
      end

      def default_notifications
        {
          enabled: false,
          quiet_hours: { enabled: false, schedule: [] },
          priority_override: :urgent,
          delay_queue_max: 100,
          max_delay: 14_400
        }
      end
    end
  end
end
