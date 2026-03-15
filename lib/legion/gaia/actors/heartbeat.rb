# frozen_string_literal: true

require 'legion/extensions/actors/every'

module Legion
  module Gaia
    module Actors
      class Heartbeat < Legion::Extensions::Actors::Every
        def runner_class
          Legion::Gaia
        end

        def runner_function
          'heartbeat'
        end

        def time
          Legion::Gaia.settings&.dig(:heartbeat_interval) || 1
        end

        def run_now?
          true
        end

        def use_runner?
          false
        end

        def check_subtask?
          false
        end

        def generate_task?
          false
        end
      end
    end
  end
end
