# frozen_string_literal: true

module Legion
  module Gaia
    module Router
      module Transport
        module Exchanges
          class Gaia < Legion::Transport::Exchange
            def exchange_name
              'gaia'
            end
          end
        end
      end
    end
  end
end
