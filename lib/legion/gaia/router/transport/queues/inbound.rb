# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Queues
          class Inbound < Legion::Transport::Queue
            def initialize(worker_id: nil, **)
              @worker_id = worker_id
              super(**)
            end

            def queue_name
              if @worker_id
                "gaia.inbound.#{@worker_id}"
              else
                'gaia.inbound'
              end
            end
          end
        end
      end
    end
  end
end
