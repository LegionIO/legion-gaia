# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module Workflow
      # A running instance of a workflow Definition.
      #
      # Each instance has:
      #   - a reference to its Definition
      #   - a current_state (Symbol)
      #   - a transition history (Array of hashes)
      #   - arbitrary metadata provided at creation
      #   - an id (auto-generated Integer, or user-supplied)
      #
      # Thread-safety: each instance holds a Mutex so concurrent calls to
      # `transition!` serialize correctly.
      class Instance
        include Legion::Logging::Helper

        attr_reader :id, :definition, :current_state, :history, :metadata, :created_at

        # @param definition [Definition]
        # @param metadata [Hash] arbitrary caller-supplied data stored on the instance
        # @param id [Integer, String, nil] optional identifier; auto-incremented if nil
        def initialize(definition:, metadata: {}, id: nil)
          @definition   = definition
          @metadata     = metadata.dup.freeze
          @id           = id || self.class.next_id
          @created_at   = Time.now
          @history      = []
          @mutex        = Mutex.new
          @current_state = definition.initial_state
        end

        # ------------------------------------------------------------------ public API

        # Attempt to transition to +to_state+, passing +ctx+ to guards,
        # checkpoints, and callbacks.
        #
        # Raises on any failure (guard rejection, checkpoint block, unknown
        # state, or invalid transition).
        #
        # @param to_state [Symbol]
        # @param ctx [Hash] passed to guards and checkpoint conditions
        # @return [self]
        def transition!(to_state, **ctx)
          to_state = to_state.to_sym
          @mutex.synchronize { perform_transition!(to_state, ctx) }
          self
        end

        # Non-raising variant — returns true on success, false on transition failure.
        # Pass strict: true to propagate unknown-state and invalid-transition errors.
        #
        # @param to_state [Symbol]
        # @param ctx [Hash]
        # @return [Boolean]
        def transition(to_state, strict: false, **ctx)
          transition!(to_state, **ctx)
          true
        rescue GuardRejected, CheckpointBlocked, UnknownState, InvalidTransition => e
          raise if strict && (e.is_a?(UnknownState) || e.is_a?(InvalidTransition))

          handle_exception(e, level: :debug, operation: 'gaia.workflow.instance.transition',
                              workflow: definition.name, to_state: to_state)
          false
        end

        # Returns true if the instance is currently in +state+.
        def in_state?(state)
          current_state == state.to_sym
        end

        # Returns true if the instance can transition to +to_state+ right now
        # (definition-level check only — does not evaluate guards).
        def can_transition_to?(to_state)
          to_state = to_state.to_sym
          definition.transitions_from(current_state).any? { |t| t[:to] == to_state }
        end

        # Returns the list of states reachable from the current state (no guard eval).
        def available_transitions
          definition.transitions_from(current_state).map { |t| t[:to] }
        end

        # Human-readable status summary
        def status
          {
            id: id,
            workflow: definition.name,
            current_state: current_state,
            history_length: history.size,
            available_transitions: available_transitions,
            created_at: created_at,
            last_transitioned_at: history.last&.dig(:at)
          }
        end

        # ------------------------------------------------------------------ class-level ID counter

        @id_counter = 0
        @id_mutex   = Mutex.new

        class << self
          def next_id
            @id_mutex.synchronize { @id_counter += 1 }
          end

          # Reset counter — for test isolation only
          def reset_id_counter!
            @id_mutex.synchronize { @id_counter = 0 }
          end
        end

        # ------------------------------------------------------------------ private

        private

        def perform_transition!(to_state, ctx)
          raise NotInitialized unless current_state

          validate_target_state!(to_state)
          transition_entry = find_transition!(to_state)
          evaluate_guard!(transition_entry, ctx)
          evaluate_exit_checkpoints!(ctx)

          fire_exit_callbacks!(current_state)
          record_transition(to_state, ctx)
          @current_state = to_state
          fire_enter_callbacks!(to_state)
        end

        def validate_target_state!(to_state)
          raise UnknownState, to_state unless definition.known_state?(to_state)
        end

        def find_transition!(to_state)
          entry = definition.transitions_from(current_state).find { |t| t[:to] == to_state }
          raise InvalidTransition.new(current_state, to_state) unless entry

          entry
        end

        def evaluate_guard!(transition_entry, ctx)
          guard = transition_entry[:guard]
          return unless guard
          return if guard.call(ctx)

          raise GuardRejected.new(current_state, transition_entry[:to], transition_entry[:guard_name])
        end

        def evaluate_exit_checkpoints!(ctx)
          definition.checkpoints_for(current_state).each do |cp|
            raise CheckpointBlocked.new(current_state, cp.name) unless cp.satisfied?(ctx)
          end
        end

        def fire_exit_callbacks!(state_sym)
          definition.exit_callbacks_for(state_sym).each { |cb| cb.call(self) }
        end

        def fire_enter_callbacks!(state_sym)
          definition.enter_callbacks_for(state_sym).each { |cb| cb.call(self) }
        end

        def record_transition(to_state, ctx)
          @history << {
            from: current_state,
            to: to_state,
            ctx: ctx,
            at: Time.now
          }
          log.info(
            'Workflow::Instance transitioned ' \
            "workflow=#{definition.name} id=#{id} from=#{current_state} to=#{to_state}"
          )
        end
      end
    end
  end
end
