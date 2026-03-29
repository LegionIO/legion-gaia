# frozen_string_literal: true

module Legion
  module Gaia
    module Workflow
      # Base error for all workflow/state machine failures
      class Error < StandardError; end

      # Raised when a transition is attempted that is not defined
      class InvalidTransition < Error
        attr_reader :from, :to

        def initialize(from, to)
          @from = from
          @to = to
          super("No valid transition from #{from.inspect} to #{to.inspect}")
        end
      end

      # Raised when a transition guard returns false
      class GuardRejected < Error
        attr_reader :from, :to, :guard_name

        def initialize(from, to, guard_name = nil)
          @from = from
          @to = to
          @guard_name = guard_name
          label = guard_name ? " (guard: #{guard_name})" : ''
          super("Transition from #{from.inspect} to #{to.inspect} rejected by guard#{label}")
        end
      end

      # Raised when a checkpoint condition is not satisfied
      class CheckpointBlocked < Error
        attr_reader :state, :checkpoint_name

        def initialize(state, checkpoint_name)
          @state = state
          @checkpoint_name = checkpoint_name
          super("Checkpoint #{checkpoint_name.inspect} not satisfied in state #{state.inspect}")
        end
      end

      # Raised when referencing an undefined state
      class UnknownState < Error
        def initialize(state)
          super("Unknown state: #{state.inspect}")
        end
      end

      # Raised when trying to transition a workflow that has no initial state set
      class NotInitialized < Error
        def initialize
          super('Workflow instance has no current state — set an initial state in the definition')
        end
      end
    end
  end
end
