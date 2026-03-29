# frozen_string_literal: true

RSpec.describe Legion::Gaia::Workflow::Instance do
  before { described_class.reset_id_counter! }

  # Build a definition for document processing
  let(:definition) do
    Legion::Gaia::Workflow::Definition.new(:doc_processing).tap do |d|
      d.state :received, initial: true
      d.state :parsing
      d.state :enriching
      d.state :indexed,  terminal: true
      d.state :failed,   terminal: true

      d.transition :received,  to: :parsing
      d.transition :parsing,   to: :enriching, guard: ->(ctx) { ctx[:parse_ok] }, guard_name: :parse_valid
      d.transition :parsing,   to: :failed
      d.transition :enriching, to: :indexed
      d.transition :enriching, to: :failed

      d.checkpoint :enriching, name: :quality_check, condition: ->(ctx) { ctx[:score].to_f >= 0.8 }
    end
  end

  subject(:instance) { described_class.new(definition: definition, metadata: { doc_id: 42 }) }

  # ------------------------------------------------------------------ initialization

  describe '#initialize' do
    it 'starts in the initial state' do
      expect(instance.current_state).to eq(:received)
    end

    it 'starts with empty history' do
      expect(instance.history).to be_empty
    end

    it 'stores metadata (frozen)' do
      expect(instance.metadata).to eq({ doc_id: 42 })
      expect(instance.metadata).to be_frozen
    end

    it 'auto-assigns an integer id' do
      expect(instance.id).to be_an(Integer)
    end

    it 'accepts an explicit id' do
      inst = described_class.new(definition: definition, id: 'custom-99')
      expect(inst.id).to eq('custom-99')
    end

    it 'records created_at' do
      expect(instance.created_at).to be_a(Time)
    end
  end

  # ------------------------------------------------------------------ transition!

  describe '#transition!' do
    it 'moves to the target state' do
      instance.transition!(:parsing)
      expect(instance.current_state).to eq(:parsing)
    end

    it 'records the transition in history' do
      instance.transition!(:parsing)
      expect(instance.history.size).to eq(1)
      expect(instance.history.first[:from]).to eq(:received)
      expect(instance.history.first[:to]).to eq(:parsing)
    end

    it 'stores the context in history' do
      defn2 = Legion::Gaia::Workflow::Definition.new(:simple).tap do |d|
        d.state :a, initial: true
        d.state :b
        d.transition :a, to: :b
      end
      inst = described_class.new(definition: defn2)
      inst.transition!(:b, reason: 'test')
      expect(inst.history.first[:ctx]).to eq({ reason: 'test' })
    end

    it 'stores a timestamp in history' do
      instance.transition!(:parsing)
      expect(instance.history.first[:at]).to be_a(Time)
    end

    it 'chains multiple transitions' do
      instance.transition!(:parsing)
      instance.transition!(:enriching, parse_ok: true)
      expect(instance.current_state).to eq(:enriching)
      expect(instance.history.size).to eq(2)
    end

    it 'returns self for chaining' do
      result = instance.transition!(:parsing)
      expect(result).to eq(instance)
    end

    it 'accepts string state names' do
      instance.transition!('parsing')
      expect(instance.current_state).to eq(:parsing)
    end

    context 'when target state is unknown' do
      it 'raises UnknownState' do
        expect { instance.transition!(:ghost) }
          .to raise_error(Legion::Gaia::Workflow::UnknownState, /ghost/)
      end
    end

    context 'when no transition is defined from current state to target' do
      it 'raises InvalidTransition' do
        expect { instance.transition!(:indexed) }
          .to raise_error(Legion::Gaia::Workflow::InvalidTransition)
      end
    end

    context 'when a guard is defined' do
      before { instance.transition!(:parsing) }

      it 'allows the transition when guard returns true' do
        expect { instance.transition!(:enriching, parse_ok: true) }.not_to raise_error
      end

      it 'raises GuardRejected when guard returns false' do
        expect { instance.transition!(:enriching, parse_ok: false) }
          .to raise_error(Legion::Gaia::Workflow::GuardRejected) do |err|
          expect(err.guard_name).to eq(:parse_valid)
        end
      end

      it 'does not change state when guard is rejected' do
        begin
          instance.transition!(:enriching, parse_ok: false)
        rescue Legion::Gaia::Workflow::GuardRejected
          nil
        end
        expect(instance.current_state).to eq(:parsing)
      end
    end

    context 'when a checkpoint is present on the current state' do
      before do
        instance.transition!(:parsing)
        instance.transition!(:enriching, parse_ok: true)
      end

      it 'allows transition when checkpoint condition is satisfied' do
        expect { instance.transition!(:indexed, score: 0.9) }.not_to raise_error
      end

      it 'raises CheckpointBlocked when checkpoint is not satisfied' do
        expect { instance.transition!(:indexed, score: 0.5) }
          .to raise_error(Legion::Gaia::Workflow::CheckpointBlocked) do |err|
          expect(err.checkpoint_name).to eq(:quality_check)
          expect(err.state).to eq(:enriching)
        end
      end

      it 'does not change state when checkpoint blocks' do
        begin
          instance.transition!(:indexed, score: 0.5)
        rescue Legion::Gaia::Workflow::CheckpointBlocked
          nil
        end
        expect(instance.current_state).to eq(:enriching)
      end
    end

    context 'on_enter callback' do
      it 'fires when entering a state' do
        entered = []
        definition.on_enter(:parsing) { |inst| entered << inst.current_state }
        instance.transition!(:parsing)
        # callback fires after state is updated
        expect(entered).to eq([:parsing])
      end

      it 'does not fire for states that were not entered' do
        entered = []
        definition.on_enter(:indexed) { |_| entered << :indexed }
        instance.transition!(:parsing)
        expect(entered).to be_empty
      end
    end

    context 'on_exit callback' do
      it 'fires when leaving a state' do
        exited = []
        definition.on_exit(:received) { |inst| exited << inst.current_state }
        instance.transition!(:parsing)
        # callback fires before state is updated — instance is still in :received
        expect(exited).to eq([:received])
      end
    end
  end

  # ------------------------------------------------------------------ transition (non-raising)

  describe '#transition' do
    it 'returns true on success' do
      expect(instance.transition(:parsing)).to be true
    end

    it 'returns false when guard rejects' do
      instance.transition(:parsing)
      expect(instance.transition(:enriching, parse_ok: false)).to be false
    end

    it 'returns false when checkpoint blocks' do
      instance.transition(:parsing)
      instance.transition(:enriching, parse_ok: true)
      expect(instance.transition(:indexed, score: 0.1)).to be false
    end

    it 'still raises InvalidTransition (programmer error)' do
      expect { instance.transition(:indexed) }
        .to raise_error(Legion::Gaia::Workflow::InvalidTransition)
    end

    it 'still raises UnknownState (programmer error)' do
      expect { instance.transition(:ghost) }
        .to raise_error(Legion::Gaia::Workflow::UnknownState)
    end
  end

  # ------------------------------------------------------------------ query helpers

  describe '#in_state?' do
    it 'returns true for current state' do
      expect(instance.in_state?(:received)).to be true
    end

    it 'returns false for other states' do
      expect(instance.in_state?(:parsing)).to be false
    end
  end

  describe '#can_transition_to?' do
    it 'returns true for a defined target' do
      expect(instance.can_transition_to?(:parsing)).to be true
    end

    it 'returns false for an undefined target from current state' do
      expect(instance.can_transition_to?(:indexed)).to be false
    end
  end

  describe '#available_transitions' do
    it 'returns reachable states from initial state' do
      expect(instance.available_transitions).to contain_exactly(:parsing)
    end

    it 'reflects transitions from new state after advancing' do
      instance.transition!(:parsing)
      expect(instance.available_transitions).to contain_exactly(:enriching, :failed)
    end
  end

  describe '#status' do
    it 'returns a hash with expected keys' do
      status = instance.status
      expect(status).to include(
        id: instance.id,
        workflow: :doc_processing,
        current_state: :received,
        history_length: 0,
        available_transitions: [:parsing]
      )
    end

    it 'includes last_transitioned_at after a transition' do
      instance.transition!(:parsing)
      expect(instance.status[:last_transitioned_at]).to be_a(Time)
    end

    it 'last_transitioned_at is nil before any transition' do
      expect(instance.status[:last_transitioned_at]).to be_nil
    end
  end

  # ------------------------------------------------------------------ thread safety

  describe 'concurrent transitions' do
    it 'serializes transitions under mutex without race conditions' do
      simple_defn = Legion::Gaia::Workflow::Definition.new(:counter).tap do |d|
        d.state :s0, initial: true
        50.times { |i| d.state :"s#{i + 1}" }
        50.times { |i| d.transition :"s#{i}", to: :"s#{i + 1}" }
      end
      inst = described_class.new(definition: simple_defn)

      threads = 50.times.map do |i|
        Thread.new do
          inst.transition!(:"s#{i + 1}") rescue nil # rubocop:disable Style/RescueModifier
        end
      end
      threads.each(&:join)

      # All successful transitions should be reflected in history
      expect(inst.history.size).to be_between(1, 50)
    end
  end

  # ------------------------------------------------------------------ id counter

  describe '.next_id' do
    it 'increments with each call' do
      a = described_class.next_id
      b = described_class.next_id
      expect(b).to eq(a + 1)
    end
  end
end
