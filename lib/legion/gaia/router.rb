# frozen_string_literal: true

require_relative 'router/worker_routing'
require_relative 'router/router_bridge'
require_relative 'router/agent_bridge'

module Legion
  module Gaia
    module Router
      def self.transport_classes_available?
        defined?(Legion::Transport::Exchange) &&
          defined?(Legion::Transport::Queue) &&
          defined?(Legion::Transport::Message)
      end
    end
  end
end

if Legion::Gaia::Router.transport_classes_available?
  require_relative 'router/transport/exchanges/gaia'
  require_relative 'router/transport/queues/inbound'
  require_relative 'router/transport/queues/outbound'
  require_relative 'router/transport/messages/input_frame_message'
  require_relative 'router/transport/messages/output_frame_message'
end
