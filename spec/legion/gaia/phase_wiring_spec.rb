# frozen_string_literal: true

RSpec.describe Legion::Gaia::PhaseWiring do
  def phase_call(handlers, phase, signals: [], prior_results: {}, **context)
    handlers.fetch(phase).call(state: {}, signals: signals, prior_results: prior_results, **context)
  end

  def trace(id:, tags:, content: 'deploy database', strength: 0.5)
    { trace_id: id, domain_tags: tags, content_payload: content, strength: strength, associated_traces: [] }
  end

  def memory_provider(traces:)
    Class.new do
      attr_reader :ranked_ids

      def initialize(traces:)
        @traces = traces
      end

      def retrieve_by_domain(domain_tag:, limit:)
        { traces: @traces.select { |item| item[:domain_tags].include?(domain_tag) }.first(limit) }
      end

      def retrieve_ranked(trace_ids:, **)
        @ranked_ids = trace_ids
        { success: true, traces: @traces.select { |item| trace_ids.include?(item[:trace_id]) }
                                        .map { |item| { trace: item, score: item[:strength] } } }
      end

      def get_trace(trace_id:)
        { trace: @traces.find { |item| item[:trace_id] == trace_id } }
      end

      def hebbian_link(trace_id_a:, trace_id_b:)
        @coactivations = (@coactivations || 0) + 1
        if @coactivations >= 2
          get_trace(trace_id: trace_id_a)[:trace][:associated_traces] << trace_id_b
          get_trace(trace_id: trace_id_b)[:trace][:associated_traces] << trace_id_a
        end
        { linked: true }
      end
    end.new(traces: traces)
  end

  describe 'authorized relevant memory' do
    it 'ranks only relevant candidates belonging to the current human, without reinforcement' do
      memory = memory_provider(traces: [
                                 trace(id: 'alice', tags: %w[deploy owner:alice]),
                                 trace(id: 'bob', tags: %w[deploy owner:bob], strength: 1.0),
                                 trace(id: 'other', tags: %w[music owner:alice], content: 'violin', strength: 1.0)
                               ])
      handlers = described_class.build_phase_handlers({ Memory_Traces: memory }, identity: 'alice')
      result = phase_call(handlers, :memory_retrieval, identity: 'alice',
                                                       signals: [{ value: 'deploy database', tags: ['deploy'] }])

      expect(memory.ranked_ids).to eq(['alice'])
      expect(result[:traces].map { |entry| entry[:trace][:trace_id] }).to eq(['alice'])
      expect(result).to include(status: :completed, meaningful: true)
    end

    it 'does not let an anonymous request see private domain candidates' do
      memory = memory_provider(traces: [trace(id: 'private', tags: %w[deploy owner:alice])])
      handlers = described_class.build_phase_handlers({ Memory_Traces: memory })
      result = phase_call(handlers, :memory_audit, signals: [{ value: 'deploy', tags: ['deploy'] }])

      expect(result).to include(status: :skipped, reason: :no_candidates, traces: [])
      expect(memory.ranked_ids).to be_nil
    end

    it 'refuses an old global-only memory API rather than borrowing its strongest traces' do
      runner = Object.new
      def runner.retrieve_ranked(**)
        raise 'must not rank without a candidate contract'
      end
      handlers = described_class.build_phase_handlers({ Memory_Traces: runner }, identity: 'alice')
      result = phase_call(handlers, :memory_retrieval, identity: 'alice', signals: [{ value: 'deploy' }])
      expect(result).to include(status: :unavailable, reason: :authorized_candidate_api_unavailable)
    end

    it 'unwraps ranked audit entries, but reports a link only after the store actually links them' do
      memory = memory_provider(traces: [trace(id: 'a', tags: %w[deploy owner:alice]),
                                        trace(id: 'b', tags: %w[deploy owner:alice])])
      handlers = described_class.build_phase_handlers({ Memory_Traces: memory, Memory_Consolidation: memory },
                                                      identity: 'alice')
      audit = phase_call(handlers, :memory_audit, identity: 'alice', signals: [{ value: 'deploy', tags: ['deploy'] }])
      first = phase_call(handlers, :association_walk, identity: 'alice', prior_results: { memory_audit: audit })
      second = phase_call(handlers, :association_walk, identity: 'alice', prior_results: { memory_audit: audit })

      expect(first).to include(coactivated: true, linked: false, trace_id_a: 'a', trace_id_b: 'b')
      expect(second).to include(linked: true, status: :completed)
    end

    it 'does not associate unrelated strong traces or cross public/private boundaries' do
      entries = [trace(id: 'private', tags: %w[deploy owner:alice]), trace(id: 'public', tags: ['deploy']),
                 trace(id: 'other', tags: %w[music owner:alice])].map { |item| { trace: item, score: 1.0 } }
      args = described_class.association_args(identity: 'alice', prior_results: { memory_audit: { traces: entries } })
      expect(args).to include(skip: true, reason: :no_related_candidates)
    end

    it 'never suppresses knowledge lookup because an unrelated memory happens to be strong' do
      args = described_class::PHASE_ARGS[:knowledge_retrieval].call(
        signals: [{ value: 'deploy diagnosis', source_type: :human_direct, principal_id: 7 }],
        prior_results: { memory_retrieval: { traces: [trace(id: 'music', tags: ['music'], strength: 1.0)] } }
      )
      expect(args).to include(text: 'deploy diagnosis', requesting_principal_id: 7)
      expect(args).not_to have_key(:skip)
    end
  end

  describe 'truthful phase outcomes' do
    it 'retains a primary failure when a later handler succeeds' do
      result = described_class.normalize_phase_result([{ success: false, error: :storage_failed },
                                                       { success: true, synced: 2 }])
      expect(result).to include(status: :failed, success: false, error: :storage_failed)
      expect(result[:handlers].last).to include(synced: 2)
    end

    it 'does not call partial availability a successful phase' do
      result = described_class.normalize_phase_result([{ cognitive_health: 0.7 },
                                                       { status: :unavailable, reason: :missing_handler }])
      expect(result).to include(status: :partial, success: false)
      expect(result[:handlers].last).to include(reason: :missing_handler)
    end

    it 'retains deferred maintenance instead of counting last maintenance totals as new work' do
      result = { decayed: 100, deferred: true, reason: :background_decay_actor }
      expect(described_class.phase_status(result)).to eq(:deferred)
      expect(described_class.meaningful_result?(result)).to be(false)
    end

    it 'does not count empty success, missing candidates, or a failed provider as useful work' do
      expect(described_class.phase_status(success: true)).to eq(:skipped)
      expect(described_class.phase_status(success: true, traces: [])).to eq(:skipped)
      expect(described_class.phase_status(success: false)).to eq(:failed)
    end

    it 'preserves the other provider outcome even when the first handler raises' do
      failed = Object.new
      def failed.reflect_on_bonds(identity:, **)
        raise "storage unavailable for #{identity}"
      end
      other = Object.new
      def other.sync_partner_knowledge(identity:, **)
        raise "background work must not execute for #{identity}"
      end
      handlers = described_class.build_phase_handlers({ Social_Attachment: failed, Social_Calibration: other },
                                                      identity: 'alice')
      result = phase_call(handlers, :partner_reflection, identity: 'alice')
      expect(result).to include(status: :failed)
      expect(result[:handlers].map { |item| item[:status] }).to eq(%i[failed deferred])
    end
  end

  describe 'decision consumers' do
    it 'uses attended input instead of the last raw signal for knowledge and prediction' do
      selected = { value: 'urgent deploy', source_type: :human_direct, principal_id: 4 }
      context = { signals: [selected, { value: 'unrelated background' }],
                  prior_results: { sensory_processing: { filtered: [selected] } },
                  identity: 'alice', exchange_id: 'e1' }
      knowledge = described_class::PHASE_ARGS[:knowledge_retrieval].call(context)
      prediction = described_class::PHASE_ARGS[:prediction_engine].call(context)
      expect(knowledge[:text]).to eq('urgent deploy')
      expect(prediction.dig(:context, :signal)).to eq(selected)
    end

    it 'does not fall back to dropped signals when attention rejects them all' do
      args = described_class::PHASE_ARGS[:knowledge_retrieval].call(
        signals: [{ value: 'background noise' }], prior_results: { sensory_processing: { filtered: [] } }
      )
      expect(args).to include(skip: true, reason: :no_attended_signal)
    end

    it 'turns a relevant correction into corrective decision input without marking a task complete' do
      memory = { traces: [{ trace: trace(id: 'c', tags: %w[deploy correction owner:alice]), score: 0.9 }] }
      state = described_class.build_cognitive_state({ memory_retrieval: memory }, identity: 'alice')
      expect(state[:reflection]).to include(pending_adaptations: 1, recent_severity: :correction)
      expect(state[:reflection][:health]).to be < 1.0
    end

    it 'keeps an intention proposal distinct from verified task completion' do
      volition = Object.new
      def volition.form_intentions(**)
        { new_intentions: [{ intention_id: 'i1', goal: 'deploy carefully' }], active_intentions: 1 }
      end
      handlers = described_class.build_phase_handlers({ Volition_Volition: volition }, identity: 'alice')
      result = phase_call(handlers, :action_selection, identity: 'alice')
      expect(result).to include(status: :completed, outcome: :intention_proposed, task_completed: false)
    end

    it 'uses measured prediction accuracy only after real outcomes exist' do
      prediction = Class.new do
        attr_accessor :outcomes

        def prediction_accuracy(identity:)
          { accuracy: 0.25, total_outcomes: (@outcomes || {}).fetch(identity, 0) }
        end

        def predict(identity:, confidence: 0.8, **)
          { prediction_id: "#{identity}:p1", confidence: confidence, actionable: confidence >= 0.5 }
        end
      end.new
      handlers = described_class.build_phase_handlers({ Prediction_Prediction: prediction }, identity: 'alice')
      initial = phase_call(handlers, :prediction_engine, identity: 'alice', signals: [{ value: 'deploy' }])
      prediction.outcomes = { 'alice' => 4 }
      calibrated = phase_call(handlers, :prediction_engine, identity: 'alice', signals: [{ value: 'deploy' }])
      expect(initial).to include(confidence: 0.8, actionable: true)
      expect(calibrated).to include(confidence: 0.25, actionable: false)
    end

    it 'generates a gradable prediction only from an explicit correlated claim and expected comparison' do
      prediction = Class.new do
        attr_reader :claims

        def predict(identity:, description: nil, context: {}, **)
          @claims ||= Hash.new { |claims, owner| claims[owner] = [] }
          @claims[identity] << { description: description, context: context }
          { prediction_id: "p#{@claims[identity].size}", confidence: 0.8 }
        end
      end.new
      handlers = described_class.build_phase_handlers({ Prediction_Prediction: prediction }, identity: 'alice')
      claim = { domain: 'deploy', description: 'The health check will pass', expected_outcome: false }
      invalid = phase_call(handlers, :prediction_engine, identity: 'alice', exchange_id: 'e1',
                                                         signals: [{ value: 'deploy' }],
                                                         prediction_request: claim.except(:expected_outcome))
      uncorrelated = phase_call(handlers, :prediction_engine, identity: 'alice', signals: [{ value: 'deploy' }],
                                                              prediction_request: claim)
      stated = phase_call(handlers, :prediction_engine, identity: 'alice', exchange_id: 'e1',
                                                        signals: [{ value: 'deploy' }], prediction_request: claim)
      heuristic = phase_call(handlers, :prediction_engine, identity: 'alice', exchange_id: 'e2',
                                                           signals: [{ value: 'deploy' }])

      expect(invalid).to include(status: :unavailable, reason: :invalid_prediction_request)
      expect(uncorrelated).to include(status: :unavailable, reason: :prediction_correlation_required)
      expect(stated).to include(prediction_id: 'p1', prediction_kind: :stated_claim, outcome_verifiable: true,
                                prediction_claim: claim)
      expect(prediction.claims['alice'].first).to include(description: claim[:description])
      expect(prediction.claims['alice'].first.dig(:context, :prediction_claim, :expected_outcome)).to be(false)
      expect(heuristic).to include(prediction_kind: :heuristic, outcome_verifiable: false, prediction_claim: nil)
    end

    it 'refuses a claim when an old provider silently swallows its description keyword' do
      prediction = Object.new
      def prediction.predict(identity:, **)
        raise "unsupported claim must not be generated for #{identity}"
      end
      handlers = described_class.build_phase_handlers({ Prediction_Prediction: prediction }, identity: 'alice')
      claim = { domain: 'deploy', description: 'The deployment will finish', expected_outcome: 'finished' }
      result = phase_call(handlers, :prediction_engine, identity: 'alice', exchange_id: 'e1',
                                                        signals: [{ value: 'deploy' }], prediction_request: claim)
      expect(result).to include(status: :unavailable, reason: :stated_prediction_unsupported)
    end

    it 'submits to and competes on the same live workspace, and feeds its winner to action selection' do
      workspace = Class.new do
        def submit_for_broadcast(content:, salience:, **)
          @candidates ||= []
          @candidates << [content, salience]
          { success: true }
        end

        def run_competition
          content, = @candidates.max_by(&:last)
          { success: true, broadcast: { content: content } }
        end
      end.new
      handlers = described_class.build_phase_handlers({ GlobalWorkspace_GlobalWorkspace: workspace }, identity: 'alice')
      attended = [{ value: 'low', attention_score: 0.2 }, { value: 'priority', attention_score: 0.95 }]
      result = phase_call(handlers, :global_workspace, identity: 'alice', conversation_id: 'c1', exchange_id: 'e1',
                                                       prior_results: { sensory_processing: { filtered: attended } })
      state = described_class.build_cognitive_state({ global_workspace: result }, identity: 'alice', signals: attended)
      expect(state.dig(:curiosity, :top_question)).to eq('priority')
      expect(state.dig(:emotion, :arousal)).to eq(0.95)
    end

    it 'does not call an empty workspace competition meaningful' do
      workspace = Object.new
      def workspace.submit_for_broadcast(**)
        raise 'no candidates'
      end

      def workspace.run_competition
        raise 'no candidates'
      end
      handlers = described_class.build_phase_handlers({ GlobalWorkspace_GlobalWorkspace: workspace })
      expect(phase_call(handlers, :global_workspace)).to include(status: :skipped, reason: :no_candidates)
    end

    it 'keeps reflection influence scoped to its human and conversation' do
      described_class.capture_tick_results(
        { post_tick_reflection: { cognitive_health: 0.2, reflections_generated: 3 } },
        identity: 'alice', conversation_id: 'c1'
      )
      expect(described_class.extract_reflection_state(identity: 'alice', conversation_id: 'c1')).to include(health: 0.2)
      expect(described_class.extract_reflection_state(identity: 'bob', conversation_id: 'c1')).to eq({})
      expect(described_class.extract_reflection_state(identity: 'alice', conversation_id: 'c2')).to eq({})
    ensure
      described_class.forget_identity(identity: 'alice')
    end

    it 'refuses a human scope on the anonymous shared handler set' do
      provider = Object.new
      def provider.filter_signals(**)
        raise 'anonymous host must not receive human state'
      end
      handlers = described_class.build_phase_handlers({ Attention_Attention: provider })
      result = phase_call(handlers, :sensory_processing, identity: 'alice', signals: [{ value: 'private' }])
      expect(result).to include(status: :unavailable, reason: :identity_mismatch)
    end
  end
end
