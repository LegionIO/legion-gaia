# frozen_string_literal: true

module Legion
  module Gaia
    module Workflow
      # Represents a named checkpoint attached to a state.
      # A checkpoint pauses progression until its condition is satisfied.
      # Unlike a guard (which is evaluated on the outgoing transition), a
      # checkpoint is evaluated when attempting to ENTER or LEAVE a state —
      # the workflow sits in a :waiting sub-status until the condition passes.
      Checkpoint = ::Data.define(:state, :name, :condition) do
        # @param ctx [Hash] arbitrary context provided by the caller
        # @return [Boolean]
        def satisfied?(ctx = {})
          condition.nil? || condition.call(ctx)
        end
      end
    end
  end
end
