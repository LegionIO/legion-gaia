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
          shutdown: { heartbeat_wait_timeout: 30.0, heartbeat_wait_log_interval: 5.0 },
          channels: default_channels,
          router: { mode: false, allowed_worker_ids: [] },
          session: { persistence: 'auto', ttl: 86_400 },
          output: { mobile_max_length: 500, suggest_channel_switch: true },
          notifications: default_notifications,
          partner: default_partner
        }
      end

      def default_partner
        {
          prior_strength: 0.5,
          r_amount: 0.1,
          direct_address_weight: 1.5,
          corroboration_weight: 1.3,
          partner_threshold: 0.6,
          identity_decay_rate: 0.002
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
          enabled: true,
          quiet_hours: { enabled: false, schedule: [] },
          priority_override: :urgent,
          delay_queue_max: 100,
          max_delay: 14_400
        }
      end
    end
  end
end
