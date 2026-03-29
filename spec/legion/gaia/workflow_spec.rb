# frozen_string_literal: true

RSpec.describe Legion::Gaia::Workflow do
  # ------------------------------------------------------------------ Workflow.define (standalone)

  describe '.define' do
    it 'returns a Definition' do
      defn = described_class.define(:my_flow) do |w|
        w.state :start, initial: true
        w.state :finish, terminal: true
        w.transition :start, to: :finish
      end

      expect(defn).to be_a(Legion::Gaia::Workflow::Definition)
      expect(defn.name).to eq(:my_flow)
    end

    it 'yields the definition as a block argument' do
      yielded = nil
      described_class.define(:test) { |w| yielded = w }
      expect(yielded).to be_a(Legion::Gaia::Workflow::Definition)
    end

    it 'works with no block' do
      defn = described_class.define(:empty)
      expect(defn.states).to eq({})
    end

    it 'can run a full workflow end-to-end' do
      defn = described_class.define(:pipeline) do |w|
        w.state :pending, initial: true
        w.state :running
        w.state :done, terminal: true

        w.transition :pending, to: :running
        w.transition :running, to: :done, guard: ->(ctx) { ctx[:success] }
      end

      inst = Legion::Gaia::Workflow::Instance.new(definition: defn)
      inst.transition!(:running)
      inst.transition!(:done, success: true)

      expect(inst.current_state).to eq(:done)
      expect(inst.history.size).to eq(2)
    end
  end

  # ------------------------------------------------------------------ include ClassMethods

  describe 'ClassMethods via include' do
    let(:host_class) do
      Class.new do
        include Legion::Gaia::Workflow
      end
    end

    describe '.workflow' do
      it 'registers a definition on the class' do
        host_class.workflow(:order_processing) do |w|
          w.state :new, initial: true
          w.state :shipped, terminal: true
          w.transition :new, to: :shipped
        end

        expect(host_class.workflow_definition(:order_processing)).to be_a(Legion::Gaia::Workflow::Definition)
      end

      it 'stores definition keyed by symbol' do
        host_class.workflow('my_flow') { |_w| nil }
        expect(host_class.workflow_definitions).to have_key(:my_flow)
      end

      it 'replaces previous definition with the same name' do
        host_class.workflow(:flow) do |w|
          w.state :a, initial: true
        end
        host_class.workflow(:flow) do |w|
          w.state :b, initial: true
        end

        defn = host_class.workflow_definition(:flow)
        expect(defn.initial_state).to eq(:b)
      end

      it 'returns the Definition' do
        result = host_class.workflow(:x) { |_w| nil }
        expect(result).to be_a(Legion::Gaia::Workflow::Definition)
      end
    end

    describe '.workflow_definitions' do
      it 'returns empty hash before any workflows are defined' do
        expect(host_class.workflow_definitions).to eq({})
      end

      it 'returns all registered definitions' do
        host_class.workflow(:a) { |_w| nil }
        host_class.workflow(:b) { |_w| nil }
        expect(host_class.workflow_definitions.keys).to contain_exactly(:a, :b)
      end
    end

    describe '.workflow_definition' do
      it 'returns nil for unknown name' do
        expect(host_class.workflow_definition(:nope)).to be_nil
      end
    end

    describe '.create_workflow' do
      before do
        host_class.workflow(:shipping) do |w|
          w.state :pending, initial: true
          w.state :shipped, terminal: true
          w.transition :pending, to: :shipped
        end
      end

      it 'creates an Instance in the initial state' do
        inst = host_class.create_workflow
        expect(inst).to be_a(Legion::Gaia::Workflow::Instance)
        expect(inst.current_state).to eq(:pending)
      end

      it 'passes metadata to the instance' do
        inst = host_class.create_workflow(metadata: { order_id: 7 })
        expect(inst.metadata).to eq({ order_id: 7 })
      end

      it 'selects definition by name' do
        host_class.workflow(:other) do |w|
          w.state :x, initial: true
        end
        inst = host_class.create_workflow(name: :other)
        expect(inst.current_state).to eq(:x)
      end

      it 'raises ArgumentError for unknown workflow name' do
        expect { host_class.create_workflow(name: :missing) }
          .to raise_error(ArgumentError, /missing/)
      end

      it 'raises ArgumentError when no workflows defined' do
        empty_class = Class.new { include Legion::Gaia::Workflow }
        expect { empty_class.create_workflow }
          .to raise_error(ArgumentError)
      end
    end
  end

  # ------------------------------------------------------------------ full integration scenario

  describe 'document processing workflow' do
    let(:host_class) do
      Class.new do
        include Legion::Gaia::Workflow

        workflow :document_processing do |w|
          w.state :received, initial: true
          w.state :parsing
          w.state :enriching
          w.state :indexed,   terminal: true
          w.state :failed,    terminal: true

          w.transition :received,  to: :parsing
          w.transition :parsing,   to: :enriching, guard: ->(ctx) { ctx[:parse_result] == :ok }
          w.transition :parsing,   to: :failed
          w.transition :enriching, to: :indexed
          w.transition :enriching, to: :failed

          w.checkpoint :enriching, name: :quality_check,
                                   condition: ->(ctx) { ctx[:quality_score].to_f >= 0.8 }
        end
      end
    end

    it 'processes a document through the happy path' do
      inst = host_class.create_workflow(metadata: { doc_id: 1 })
      inst.transition!(:parsing)
      inst.transition!(:enriching, parse_result: :ok)
      inst.transition!(:indexed, quality_score: 0.9)

      expect(inst.current_state).to eq(:indexed)
      expect(inst.history.size).to eq(3)
    end

    it 'routes to failed on parse error' do
      inst = host_class.create_workflow
      inst.transition!(:parsing)
      inst.transition!(:failed)
      expect(inst.current_state).to eq(:failed)
    end

    it 'blocks at quality checkpoint' do
      inst = host_class.create_workflow
      inst.transition!(:parsing)
      inst.transition!(:enriching, parse_result: :ok)
      expect { inst.transition!(:indexed, quality_score: 0.5) }
        .to raise_error(Legion::Gaia::Workflow::CheckpointBlocked)
    end

    it 'fires on_enter callbacks registered after definition' do
      defn = host_class.workflow_definition(:document_processing)
      indexed_events = []
      defn.on_enter(:indexed) { |i| indexed_events << i.id }

      inst = host_class.create_workflow
      inst.transition!(:parsing)
      inst.transition!(:enriching, parse_result: :ok)
      inst.transition!(:indexed, quality_score: 1.0)

      expect(indexed_events).to include(inst.id)
    end
  end

  # ------------------------------------------------------------------ deployment pipeline scenario

  describe 'deployment pipeline workflow' do
    let(:definition) do
      described_class.define(:deployment) do |w|
        w.state :building, initial: true
        w.state :testing
        w.state :staging
        w.state :production, terminal: true
        w.state :rolled_back, terminal: true

        w.transition :building,   to: :testing,    guard: ->(ctx) { ctx[:build_success] }
        w.transition :testing,    to: :staging,    guard: ->(ctx) { ctx[:tests_passed] }
        w.transition :staging,    to: :production, guard: ->(ctx) { ctx[:canary_ok] }
        w.transition :testing,    to: :rolled_back
        w.transition :staging,    to: :rolled_back
        w.transition :production, to: :rolled_back
      end
    end

    it 'progresses through the full deployment pipeline' do
      inst = Legion::Gaia::Workflow::Instance.new(definition: definition)
      inst.transition!(:testing,    build_success: true)
      inst.transition!(:staging,    tests_passed: true)
      inst.transition!(:production, canary_ok: true)

      expect(inst.current_state).to eq(:production)
      expect(inst.history.map { |h| h[:to] }).to eq(%i[testing staging production])
    end

    it 'can rollback from staging' do
      inst = Legion::Gaia::Workflow::Instance.new(definition: definition)
      inst.transition!(:testing,    build_success: true)
      inst.transition!(:staging,    tests_passed: true)
      inst.transition!(:rolled_back)
      expect(inst.current_state).to eq(:rolled_back)
    end

    it 'blocks on failed build guard' do
      inst = Legion::Gaia::Workflow::Instance.new(definition: definition)
      expect { inst.transition!(:testing, build_success: false) }
        .to raise_error(Legion::Gaia::Workflow::GuardRejected)
    end
  end
end
