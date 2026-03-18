# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Queues
          class Inbound < Legion::Transport::Queues::Agent
            def initialize(worker_id: nil, **)
              super(agent_id: worker_id, **)
            end
          end
        end
      end
    end
  end
end
