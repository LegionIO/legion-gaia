# frozen_string_literal: true

RSpec.describe Legion::Gaia::Workflow::Definition do
  subject(:defn) { described_class.new(:pipeline) }

  describe '#initialize' do
    it 'stores the name as a symbol' do
      expect(defn.name).to eq(:pipeline)
    end

    it 'starts with empty states, transitions, checkpoints, and callbacks' do
      expect(defn.states).to eq({})
      expect(defn.transitions).to eq({})
      expect(defn.checkpoints).to eq({})
      expect(defn.callbacks).to eq({})
      expect(defn.initial_state).to be_nil
    end
  end

  describe '#state' do
    it 'registers a state' do
      defn.state(:pending)
      expect(defn.known_state?(:pending)).to be true
    end

    it 'accepts string names and normalizes to symbol' do
      defn.state('running')
      expect(defn.known_state?(:running)).to be true
    end

    it 'sets initial_state when initial: true' do
      defn.state(:start, initial: true)
      expect(defn.initial_state).to eq(:start)
    end

    it 'last initial: true wins' do
      defn.state(:a, initial: true)
      defn.state(:b, initial: true)
      expect(defn.initial_state).to eq(:b)
    end

    it 'does not set initial_state when initial: false' do
      defn.state(:pending, initial: false)
      expect(defn.initial_state).to be_nil
    end

    it 'records terminal flag' do
      defn.state(:done, terminal: true)
      expect(defn.states[:done][:terminal]).to be true
    end
  end

  describe '#transition' do
    before do
      defn.state(:pending)
      defn.state(:running)
      defn.state(:done)
    end

    it 'registers a transition' do
      defn.transition(:pending, to: :running)
      expect(defn.transitions_from(:pending)).to include(a_hash_including(to: :running))
    end

    it 'normalizes string names to symbols' do
      defn.transition('pending', to: 'running')
      expect(defn.transitions_from(:pending).first[:to]).to eq(:running)
    end

    it 'stores a guard proc' do
      guard = ->(ctx) { ctx[:ready] }
      defn.transition(:pending, to: :running, guard: guard)
      entry = defn.transitions_from(:pending).first
      expect(entry[:guard]).to eq(guard)
    end

    it 'stores a guard_name' do
      defn.transition(:pending, to: :running, guard: ->(_) { true }, guard_name: :readiness)
      entry = defn.transitions_from(:pending).first
      expect(entry[:guard_name]).to eq(:readiness)
    end

    it 'allows multiple transitions from the same state' do
      defn.transition(:pending, to: :running)
      defn.transition(:pending, to: :done)
      targets = defn.transitions_from(:pending).map { |t| t[:to] }
      expect(targets).to contain_exactly(:running, :done)
    end

    it 'returns empty array for unknown state' do
      expect(defn.transitions_from(:unknown)).to eq([])
    end
  end

  describe '#checkpoint' do
    before { defn.state(:enriching) }

    it 'registers a checkpoint for a state' do
      defn.checkpoint(:enriching, name: :quality_check, condition: ->(ctx) { ctx[:score] >= 0.8 })
      expect(defn.checkpoints_for(:enriching).size).to eq(1)
    end

    it 'stores checkpoint name' do
      defn.checkpoint(:enriching, name: :quality_check)
      cp = defn.checkpoints_for(:enriching).first
      expect(cp.name).to eq(:quality_check)
    end

    it 'allows multiple checkpoints on the same state' do
      defn.checkpoint(:enriching, name: :first)
      defn.checkpoint(:enriching, name: :second)
      expect(defn.checkpoints_for(:enriching).size).to eq(2)
    end

    it 'returns empty array for state with no checkpoints' do
      expect(defn.checkpoints_for(:enriching)).to eq([])
    end
  end

  describe '#on_enter' do
    before { defn.state(:done) }

    it 'registers an enter callback' do
      called_with = nil
      defn.on_enter(:done) { |inst| called_with = inst }
      cbs = defn.enter_callbacks_for(:done)
      expect(cbs.size).to eq(1)
      cbs.first.call(:fake_instance)
      expect(called_with).to eq(:fake_instance)
    end

    it 'allows multiple enter callbacks on the same state' do
      defn.on_enter(:done) { |_| nil }
      defn.on_enter(:done) { |_| nil }
      expect(defn.enter_callbacks_for(:done).size).to eq(2)
    end

    it 'returns empty array for state with no callbacks' do
      defn.state(:pending)
      expect(defn.enter_callbacks_for(:pending)).to eq([])
    end
  end

  describe '#on_exit' do
    before { defn.state(:running) }

    it 'registers an exit callback' do
      called = false
      defn.on_exit(:running) { |_inst| called = true }
      defn.exit_callbacks_for(:running).first.call(nil)
      expect(called).to be true
    end

    it 'allows multiple exit callbacks' do
      defn.on_exit(:running) { |_| nil }
      defn.on_exit(:running) { |_| nil }
      expect(defn.exit_callbacks_for(:running).size).to eq(2)
    end
  end

  describe '#known_state?' do
    it 'returns true for registered states' do
      defn.state(:active)
      expect(defn.known_state?(:active)).to be true
    end

    it 'returns false for unknown states' do
      expect(defn.known_state?(:ghost)).to be false
    end

    it 'accepts string input' do
      defn.state(:active)
      expect(defn.known_state?('active')).to be true
    end
  end
end
