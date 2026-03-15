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
          channels: {
            cli: { enabled: true },
            teams: { enabled: false },
            slack: { enabled: false }
          },
          router: {
            mode: false,
            allowed_worker_ids: []
          },
          session: {
            persistence: 'auto',
            ttl: 86_400
          },
          output: {
            mobile_max_length: 500,
            suggest_channel_switch: true
          }
        }
      end
    end
  end
end
