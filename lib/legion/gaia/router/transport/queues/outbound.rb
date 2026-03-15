# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Queues
          class Outbound < Legion::Transport::Queue
            def queue_name
              'gaia.outbound'
            end
          end
        end
      end
    end
  end
end
