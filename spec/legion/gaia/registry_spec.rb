# frozen_string_literal: true

RSpec.describe Legion::Gaia::Registry do
  subject(:registry) { described_class.instance }

  let(:attention) do
    Module.new do
      def filter_signals(signals:, **)
        @seen = (@seen || 0) + signals.size
        { filtered: signals, seen: @seen }
      end
    end
  end

  let(:tick) do
    Module.new do
      def execute_tick(enabled_optional_phases: [], **)
        { enabled: enabled_optional_phases }
      end
    end
  end

  before do
    registry.reset!
    allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).and_return(nil)
    allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).with(:Attention,
                                                                            :Attention).and_return(attention)
    allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).with(:Tick, :Orchestrator).and_return(tick)
  end

  after { registry.reset! }

  it 'retains live runner state across rediscovery while separating two humans and anonymous work' do
    registry.discover
    alice = registry.runner_instances_for(identity: 'alice')[:Attention_Attention]
    bob = registry.runner_instances_for(identity: 'bob')[:Attention_Attention]
    alice.filter_signals(signals: [{ value: 'one' }])
    registry.rediscover

    retained = registry.runner_instances_for(identity: 'alice')[:Attention_Attention]
    expect(retained.filter_signals(signals: [{ value: 'two' }])[:seen]).to eq(2)
    expect(bob.filter_signals(signals: [{ value: 'bob' }])[:seen]).to eq(1)
    expect(registry.runner_instances[:Attention_Attention].filter_signals(signals: [])[:seen]).to eq(0)
  end

  it 'refuses tick opt-in when an old provider would silently swallow the keyword' do
    old_tick = Module.new do
      def execute_tick(**)
        { ignored: true }
      end
    end
    allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).with(:Tick, :Orchestrator).and_return(old_tick)
    registry.discover
    expect(registry.supported_optional_phases(identity: 'alice', requested: [:global_workspace])).to eq([])
  end

  it 'does not activate optional phases merely because their providers are loaded' do
    registry.discover
    expect(registry.supported_optional_phases(identity: 'alice', requested: [])).to eq([])
    expect(registry.supported_optional_phases(identity: 'alice',
                                              requested: [:global_workspace])).to eq([:global_workspace])
    expect do
      registry.supported_optional_phases(identity: 'alice', requested: [:free_energy])
    end.to raise_error(ArgumentError)
  end

  it 'requires demonstrated meaningful work and preserves its last outcome through a later budget skip' do
    registry.discover
    before = registry.capabilities_for(identity: 'alice')[:sensory_processing]
    expect(before).to include(loaded: true, ready: false)
    registry.record_tick_result(
      result: { results: { sensory_processing: { filtered: [{ value: 'input' }], status: :completed } } },
      identity: 'alice', conversation_id: 'c1'
    )
    after = registry.capabilities_for(identity: 'alice')[:sensory_processing]
    expect(after).to include(ready: true)
    expect(registry.capabilities_for(identity: 'bob')[:sensory_processing]).to include(ready: false)

    registry.record_tick_result(result: { results: {}, phases_skipped: [:sensory_processing] }, identity: 'alice',
                                conversation_id: 'c1')
    skipped = registry.capabilities_for(identity: 'alice')[:sensory_processing]
    expect(skipped).to include(ready: false, status: :budget_skipped, reason: :tick_budget_exhausted)
    expect(skipped[:last_meaningful_at]).to eq(after[:last_meaningful_at])
  end

  it 'consumes demonstrated metacognition instead of treating loaded constants as readiness' do
    registry.discover
    registry.record_tick_result(identity: 'alice', conversation_id: 'c1', result: {
                                  results: {
                                    sensory_processing: { filtered: [{ value: 'input' }] },
                                    metacognition: { cognitive: { health: 0.6 }, demonstrated_capabilities: {
                                      sensory_processing: { status: :completed, ready: true }
                                    } }
                                  }
                                })
    capability = registry.capabilities_for(identity: 'alice')[:sensory_processing]
    expect(capability[:metacognition]).to eq(status: :completed, ready: true)
    outcome = registry.capabilities_for(identity: 'alice')[:metacognition][:last_meaningful_outcome]
    expect(outcome).to include(cognitive_health: 0.6,
                               assessments: { sensory_processing: { status: :completed, ready: true } })
  end

  it 'returns only the requested human/conversation snapshot and does not expose mutable internal state' do
    registry.record_tick_result(
      result: { results: { memory_retrieval: { traces: [{ trace: { trace_id: 'alice-secret' } }] } } },
      identity: 'alice', conversation_id: 'one'
    )
    registry.record_tick_result(result: { results: { sensory_processing: { filtered: [{ value: 'other' }] } } },
                                identity: 'bob', conversation_id: 'two')
    snapshot = registry.tick_result_for(identity: 'alice', conversation_id: 'one')
    snapshot[:results][:memory_retrieval][:traces].clear
    expect(registry.tick_result_for(identity: 'alice', conversation_id: 'two')).to be_nil
    expect(registry.tick_result_for(identity: 'alice', conversation_id: 'one').dig(:results, :memory_retrieval,
                                                                                   :traces))
      .to eq([{ trace: { trace_id: 'alice-secret' } }])
  end

  it 'removes scoped state and snapshots so rediscovery cannot restore a forgotten host' do
    registry.discover
    host = registry.runner_instances_for(identity: 'alice')[:Attention_Attention]
    host.filter_signals(signals: [{ value: 'private' }])
    registry.record_tick_result(result: { results: { sensory_processing: { filtered: [{ value: 'private' }] } } },
                                identity: 'alice', conversation_id: 'one')
    registry.erase_identity(identity: 'alice')
    registry.rediscover
    restored = registry.runner_instances_for(identity: 'alice')[:Attention_Attention]
    expect(restored.filter_signals(signals: [])[:seen]).to eq(0)
    expect(registry.tick_result_for(identity: 'alice', conversation_id: 'one')).to be_nil
  end

  describe 'verified outcome consumption' do
    let(:evidence) { { source: :human_confirmation, observed_outcome: 'deployment completed' } }
    let(:claim) { { domain: 'deploy', description: 'The health check will pass', expected_outcome: true } }

    let(:volition) do
      Module.new do
        def form_intentions(**)
          { new_intentions: [{ intention_id: 'i1', goal: 'deploy carefully' }],
            current_intention: { intention_id: 'i1', goal: 'deploy carefully' } }
        end

        def complete_intention(intention_id:)
          @completed = (@completed || 0) + 1
          { status: :completed, intention_id: intention_id, completion_count: @completed }
        end
      end
    end

    before do
      allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).with(:Volition, :Volition).and_return(volition)
      registry.discover
      registry.record_tick_result(identity: 'alice', conversation_id: 'c1', exchange_id: 'e1', result: {
                                    results: { action_selection: {
                                      new_intentions: [{ intention_id: 'i1', goal: 'deploy carefully' }],
                                      task_completed: false
                                    } }
                                  })
    end

    it 'does not complete an intention from a proposal, another exchange, or another human' do
      expect(registry.record_outcome(identity: 'alice', exchange_id: 'e1', outcome: :completed, intention_id: 'i1'))
        .to include(reason: :unverified_outcome)
      wrong_exchange = registry.record_outcome(
        identity: 'alice', exchange_id: 'e2', outcome: :completed, intention_id: 'i1', verified: true, actual: evidence
      )
      wrong_human = registry.record_outcome(identity: 'bob', exchange_id: 'e1', outcome: :completed, intention_id: 'i1',
                                            verified: true, actual: evidence)
      expect(wrong_exchange[:intention]).to include(reason: :unmatched_outcome)
      expect(wrong_human[:intention]).to include(reason: :unmatched_outcome)
    end

    it 'completes the matching live intention exactly once' do
      first = registry.record_outcome(identity: 'alice', exchange_id: 'e1', outcome: :completed, intention_id: 'i1',
                                      verified: true, actual: evidence)
      duplicate = registry.record_outcome(identity: 'alice', exchange_id: 'e1', outcome: :completed, intention_id: 'i1',
                                          verified: true, actual: evidence)
      expect(first[:intention]).to include(
        status: :completed, completion_count: 1, evidence_source: :human_confirmation, goal: 'deploy carefully'
      )
      expect(duplicate[:intention]).to include(reason: :already_resolved)
    end

    it 'resolves only a matching scoped prediction and rejects duplicate attribution' do
      prediction = Module.new do
        def predict(identity:, description: nil, context: {}, **)
          @claims ||= {}
          @claims[identity] = { description: description, context: context }
          { prediction_id: 'p1', confidence: 0.8 }
        end

        def resolve_prediction(prediction_id:, outcome:, identity:, actual: nil)
          claim = @claims.fetch(identity)
          matches = actual[:observed_outcome] == claim.dig(:context, :prediction_claim, :expected_outcome)
          return { resolved: false } unless outcome == (matches ? :correct : :incorrect)

          @resolved_count = (@resolved_count || 0) + 1
          { resolved: true, prediction_id: prediction_id, description: claim[:description],
            outcome: outcome, count: @resolved_count }
        end
      end
      allow(Legion::Gaia::PhaseWiring).to receive(:resolve_runner_class).with(:Prediction,
                                                                              :Prediction).and_return(prediction)
      registry.rediscover
      generated = registry.phase_handlers_for(identity: 'alice')[:prediction_engine].call(
        state: {}, signals: [{ value: 'deploy now' }], prior_results: {}, identity: 'alice', conversation_id: 'c1',
        exchange_id: 'e1', prediction_request: claim
      )
      registry.record_tick_result(identity: 'alice', conversation_id: 'c1', exchange_id: 'e1',
                                  result: { results: { prediction_engine: generated } })
      observed = { source: :human_confirmation, observed_outcome: false }
      contradictory = registry.record_outcome(
        identity: 'alice', exchange_id: 'e1', prediction_id: 'p1', outcome: :correct, verified: true, actual: observed
      )
      wrong = registry.record_outcome(identity: 'bob', exchange_id: 'e1', prediction_id: 'p1', outcome: :incorrect,
                                      verified: true, actual: observed)
      first = registry.record_outcome(identity: 'alice', exchange_id: 'e1', prediction_id: 'p1', outcome: :incorrect,
                                      verified: true, actual: observed)
      duplicate = registry.record_outcome(
        identity: 'alice', exchange_id: 'e1', prediction_id: 'p1', outcome: :incorrect, verified: true, actual: observed
      )
      expect(wrong[:prediction]).to include(reason: :unmatched_outcome)
      expect(contradictory[:prediction]).to include(reason: :outcome_comparison_mismatch)
      expect(first[:prediction]).to include(
        resolved: true, outcome: :incorrect, count: 1, evidence_source: :human_confirmation,
        prediction_claim: claim, observed_outcome: false
      )
      expect(duplicate[:prediction]).to include(reason: :already_resolved)
    end

    it 'refuses to grade a heuristic prediction or an unauthenticated machine-success-shaped report' do
      registry.record_tick_result(identity: 'alice', conversation_id: 'c1', exchange_id: 'e1',
                                  result: { results: { prediction_engine: { prediction_id: 'heuristic', confidence: 0.8,
                                                                            outcome_verifiable: false } } })
      heuristic = registry.record_outcome(identity: 'alice', exchange_id: 'e1', prediction_id: 'heuristic',
                                          outcome: :correct, verified: true, actual: evidence)
      unsupported = registry.record_outcome(identity: 'alice', exchange_id: 'e1', intention_id: 'i1',
                                            outcome: :completed, verified: true,
                                            actual: {
                                              source: :provider_completion, observed_outcome: 'tool requested'
                                            })
      missing_observation = registry.record_outcome(
        identity: 'alice', exchange_id: 'e1', intention_id: 'i1', outcome: :completed, verified: true,
        actual: { source: :human_confirmation }
      )
      expect(heuristic[:prediction]).to include(reason: :unverifiable_prediction)
      expect(unsupported).to include(reason: :outcome_evidence_required)
      expect(missing_observation).to include(reason: :outcome_evidence_required)
    end
  end
end
