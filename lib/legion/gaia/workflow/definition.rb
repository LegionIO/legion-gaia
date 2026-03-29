# frozen_string_literal: true

module Legion
  module Gaia
    module Workflow
      # DSL class that captures a state machine definition.
      #
      # Usage (inside a `workflow` block):
      #
      #   state :pending, initial: true
      #   state :running
      #   state :done
      #
      #   transition :pending, to: :running
      #   transition :running, to: :done, guard: ->(ctx) { ctx[:result].present? }
      #
      #   checkpoint :running, name: :quality_check, condition: ->(ctx) { ctx[:score] >= 0.8 }
      #
      #   on_enter(:done) { |instance| puts "finished" }
      #   on_exit(:running) { |instance| puts "leaving running" }
      class Definition
        attr_reader :name, :states, :transitions, :checkpoints, :callbacks, :initial_state

        def initialize(name)
          @name = name
          @states = {}          # { state_sym => { terminal: bool } }
          @transitions = {}     # { from_sym => [{ to:, guard:, guard_name: }] }
          @checkpoints = {}     # { state_sym => [Checkpoint] }
          @callbacks = {}       # { :enter/:exit => { state_sym => [callable] } }
          @initial_state = nil
        end

        # ------------------------------------------------------------------ DSL

        # Declare a state.
        # @param name [Symbol]
        # @param initial [Boolean] marks this as the default start state
        # @param terminal [Boolean] no transitions out are expected (informational)
        def state(name, initial: false, terminal: false)
          name = name.to_sym
          @states[name] = { terminal: terminal }
          @initial_state = name if initial
        end

        # Declare a valid transition.
        # @param from [Symbol] source state
        # @param to [Symbol] target state
        # @param guard [#call, nil] optional lambda `(ctx) -> bool`
        # @param guard_name [Symbol, String, nil] label for error messages
        def transition(from, to:, guard: nil, guard_name: nil)
          from = from.to_sym
          to   = to.to_sym
          @transitions[from] ||= []
          @transitions[from] << { to: to, guard: guard, guard_name: guard_name }
        end

        # Declare a checkpoint that must pass before leaving a state.
        # @param state_name [Symbol]
        # @param name [Symbol] identifier for the checkpoint
        # @param condition [#call, nil] lambda `(ctx) -> bool`; nil means always pass
        def checkpoint(state_name, name:, condition: nil)
          state_name = state_name.to_sym
          @checkpoints[state_name] ||= []
          @checkpoints[state_name] << Checkpoint.new(
            state: state_name,
            name: name,
            condition: condition
          )
        end

        # Register a callback to fire when a state is entered.
        # @param state_name [Symbol]
        # @yield [instance] receives the workflow Instance
        def on_enter(state_name, &block)
          register_callback(:enter, state_name.to_sym, block)
        end

        # Register a callback to fire when a state is exited.
        # @param state_name [Symbol]
        # @yield [instance] receives the workflow Instance
        def on_exit(state_name, &block)
          register_callback(:exit, state_name.to_sym, block)
        end

        # ------------------------------------------------------------------ query helpers

        def known_state?(state_sym)
          @states.key?(state_sym.to_sym)
        end

        # Returns all outgoing transition entries from a state.
        def transitions_from(from_sym)
          @transitions[from_sym.to_sym] || []
        end

        # Returns matching checkpoint entries for a state (may be empty).
        def checkpoints_for(state_sym)
          @checkpoints[state_sym.to_sym] || []
        end

        # Returns on_enter callbacks for a state (array, may be empty).
        def enter_callbacks_for(state_sym)
          @callbacks.dig(:enter, state_sym.to_sym) || []
        end

        # Returns on_exit callbacks for a state (array, may be empty).
        def exit_callbacks_for(state_sym)
          @callbacks.dig(:exit, state_sym.to_sym) || []
        end

        # ------------------------------------------------------------------ private

        private

        def register_callback(type, state_sym, block)
          @callbacks[type] ||= {}
          @callbacks[type][state_sym] ||= []
          @callbacks[type][state_sym] << block
        end
      end
    end
  end
end
