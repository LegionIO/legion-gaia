# frozen_string_literal: true

require 'timeout'

RSpec.describe Legion::Gaia do
  let(:store) { double('PrivateStore', query_by_tags: { success: true, results: [] }, upsert: { success: true }) }

  before do
    stub_const('Legion::Logging', logging_stub)
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
    allow(described_class).to receive(:apollo_local_store).and_return(store)
  end

  after do
    described_class.shutdown if described_class.started?
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
  end

  describe '.boot' do
    it 'starts GAIA and sets started? to true' do
      described_class.boot
      expect(described_class.started?).to be true
    end

    it 'keeps anonymous operation available while private lifecycle storage is unavailable' do
      allow(described_class).to receive(:apollo_local_store).and_return(nil)
      described_class.boot
      expect(described_class.status[:persistence_ready]).to be false
      private_frame = Legion::Gaia::InputFrame.new(content: 'private', channel_id: :cli,
                                                   auth_context: { principal_id: 'A' })
      public_frame = Legion::Gaia::InputFrame.new(content: 'public', channel_id: :cli)
      expect(described_class.ingest(private_frame)[:ingested]).to be false
      expect(described_class.ingest(public_frame)[:ingested]).to be true
      expect(described_class.sensory_buffer.drain.map { |signal| signal[:value] }).to eq(['public'])
    end
  end

  describe '.shutdown' do
    it 'sets started? to false' do
      described_class.boot
      described_class.shutdown
      expect(described_class.started?).to be false
    end

    it 'clears sensory buffer and registry' do
      described_class.boot
      described_class.shutdown
      expect(described_class.sensory_buffer).to be_nil
      expect(described_class.registry).to be_nil
    end

    it 'waits for an in-flight heartbeat before reporting shutdown complete' do
      heartbeat_thread = nil
      release_heartbeat = nil
      shutdown_thread = nil
      described_class.boot
      registry = described_class.registry
      tick_host = instance_double('TickHost')
      heartbeat_entered = Queue.new
      release_heartbeat = Queue.new
      shutdown_completed = Queue.new

      allow(registry).to receive(:tick_host).and_return(tick_host)
      allow(registry).to receive(:phase_handlers).and_return({})
      allow(tick_host).to receive(:execute_tick) do
        heartbeat_entered << true
        release_heartbeat.pop
        { results: {} }
      end
      allow(tick_host).to receive(:last_tick_result=)

      heartbeat_thread = Thread.new { described_class.heartbeat }
      Timeout.timeout(2) { heartbeat_entered.pop }

      shutdown_thread = Thread.new do
        described_class.shutdown
        shutdown_completed << true
      end

      Timeout.timeout(2) { sleep 0.01 until described_class.shutting_down? }
      expect(shutdown_completed.empty?).to be true

      release_heartbeat << true
      heartbeat_thread.join
      shutdown_thread.join
      expect(shutdown_completed.empty?).to be false
    ensure
      release_heartbeat << true if release_heartbeat
      heartbeat_thread&.join(1)
      shutdown_thread&.join(1)
    end

    it 'continues shutdown after the heartbeat wait timeout expires' do
      heartbeat_thread = nil
      described_class.boot
      registry = described_class.registry
      tick_host = instance_double('TickHost')
      heartbeat_entered = Queue.new
      release_heartbeat = Queue.new

      allow(described_class).to receive(:shutdown_heartbeat_wait_timeout).and_return(0.01)
      allow(described_class).to receive(:shutdown_heartbeat_wait_log_interval).and_return(0.01)
      allow(registry).to receive(:tick_host).and_return(tick_host)
      allow(registry).to receive(:phase_handlers).and_return({})
      allow(tick_host).to receive(:execute_tick) do
        heartbeat_entered << true
        release_heartbeat.pop
        { results: {} }
      end
      allow(tick_host).to receive(:last_tick_result=)

      heartbeat_thread = Thread.new { described_class.heartbeat }
      Timeout.timeout(2) { heartbeat_entered.pop }

      expect { Timeout.timeout(1) { described_class.shutdown } }.not_to raise_error
      expect(described_class.started?).to be false
    ensure
      release_heartbeat << true if release_heartbeat
      heartbeat_thread&.join(1)
    end
  end

  describe '.heartbeat' do
    it 'returns error when not started' do
      result = described_class.heartbeat
      expect(result[:error]).to eq(:not_started)
    end

    it 'returns error when lex-tick not available' do
      described_class.boot
      result = described_class.heartbeat
      expect(result[:error]).to eq(:no_tick_extension)
    end

    it 'retains input when the scheduler is unavailable' do
      described_class.boot
      frame = Legion::Gaia::InputFrame.new(content: 'do not lose this', channel_id: :cli)
      described_class.ingest(frame)
      expect(described_class.heartbeat).to include(error: :no_tick_extension)
      expect(described_class.sensory_buffer.drain.map { |signal| signal[:value] }).to eq(['do not lose this'])
    end

    it 'does not start a new heartbeat after shutdown begins' do
      heartbeat_thread = nil
      release_heartbeat = nil
      shutdown_thread = nil
      described_class.boot
      registry = described_class.registry
      tick_host = instance_double('TickHost')
      heartbeat_entered = Queue.new
      release_heartbeat = Queue.new
      execute_count = 0
      execute_count_mutex = Mutex.new

      allow(registry).to receive(:tick_host).and_return(tick_host)
      allow(registry).to receive(:phase_handlers).and_return({})
      allow(tick_host).to receive(:execute_tick) do
        count = execute_count_mutex.synchronize do
          execute_count += 1
        end
        if count == 1
          heartbeat_entered << true
          release_heartbeat.pop
        end
        { results: {} }
      end
      allow(tick_host).to receive(:last_tick_result=)

      heartbeat_thread = Thread.new { described_class.heartbeat }
      Timeout.timeout(2) { heartbeat_entered.pop }
      shutdown_thread = Thread.new { described_class.shutdown }
      Timeout.timeout(2) { sleep 0.01 until described_class.shutting_down? }

      expect(described_class.heartbeat).to eq({ error: :not_started })

      release_heartbeat << true
      heartbeat_thread.join
      shutdown_thread.join
      expect(execute_count).to eq(1)
    ensure
      release_heartbeat << true if release_heartbeat
      heartbeat_thread&.join(1)
      shutdown_thread&.join(1)
    end

    it 'does not invoke phase handlers after shutdown starts' do
      heartbeat_thread = nil
      release_phase_call = nil
      shutdown_thread = nil
      described_class.boot
      registry = described_class.registry
      tick_host = instance_double('TickHost')
      heartbeat_entered = Queue.new
      release_phase_call = Queue.new
      phase_invoked = false

      phase_handler = lambda do |**|
        phase_invoked = true
        { invoked: true }
      end

      allow(registry).to receive(:tick_host).and_return(tick_host)
      allow(registry).to receive(:phase_handlers).and_return({ prediction_engine: phase_handler })
      allow(tick_host).to receive(:execute_tick) do |phase_handlers:, **|
        heartbeat_entered << true
        release_phase_call.pop
        phase_result = phase_handlers[:prediction_engine].call(
          state: {},
          signals: [],
          prior_results: {},
          context: {}
        )
        { results: { prediction_engine: phase_result } }
      end
      allow(tick_host).to receive(:last_tick_result=)

      heartbeat_thread = Thread.new { described_class.heartbeat }
      Timeout.timeout(2) { heartbeat_entered.pop }
      shutdown_thread = Thread.new { described_class.shutdown }
      Timeout.timeout(2) { sleep 0.01 until described_class.shutting_down? }

      release_phase_call << true
      heartbeat_thread.join
      shutdown_thread.join

      expect(phase_invoked).to be false
    ensure
      release_phase_call << true if release_phase_call
      heartbeat_thread&.join(1)
      shutdown_thread&.join(1)
    end

    it 'uses status-shaped skip results for quiescing phase handlers' do
      described_class.boot
      handlers = { prediction_engine: ->(**) { { invoked: true } } }
      wrapped = described_class.send(:quiescing_phase_handlers, handlers)

      described_class.instance_variable_set(:@shutting_down, true)

      expect(wrapped[:prediction_engine].call).to eq({ status: :skipped, reason: :gaia_shutting_down })
    end
  end

  describe 'background partner isolation' do
    it 'does not infer a human or private absence from anonymous ticks' do
      described_class.boot
      tick = instance_double('TickHost', execute_tick: { results: {} })
      allow(described_class.registry).to receive(:tick_host).and_return(tick)
      handlers = { prediction_engine: ->(**) { {} }, action_selection: ->(**) { {} } }
      allow(described_class.registry).to receive(:phase_handlers).and_return(handlers)
      6.times { described_class.heartbeat }
      expect(Legion::Gaia::BondRegistry.partner_entry).to be_nil
      expect(described_class.sensory_buffer.drain).to be_empty
      expect(described_class.last_valences).to eq([])
    end
  end

  describe '.status' do
    it 'returns started: false when not booted' do
      expect(described_class.status).to eq({ started: false })
    end

    it 'returns full status when booted' do
      described_class.boot
      status = described_class.status
      expect(status[:started]).to be true
      expect(status).to have_key(:extensions_loaded)
      expect(status).to have_key(:wired_phases)
      expect(status).to have_key(:buffer_depth)
      expect(status[:notification_gate]).to include(:schedule, :presence, :behavioral)
    end
  end

  describe '.boot with router mode' do
    it 'boots in router mode' do
      described_class.boot(mode: :router)
      expect(described_class.router_mode?).to be true
      expect(described_class.router_bridge).to be_a(Legion::Gaia::Router::RouterBridge)
      expect(described_class.sensory_buffer).to be_nil
      expect(described_class.registry).to be_nil
    end

    it 'boots in agent mode by default' do
      described_class.boot
      expect(described_class.router_mode?).to be false
      expect(described_class.sensory_buffer).to be_a(Legion::Gaia::SensoryBuffer)
    end

    it 'includes mode in status' do
      described_class.boot(mode: :router)
      status = described_class.status
      expect(status[:mode]).to eq(:router)
      expect(status[:router_routes]).to eq(0)
    end
  end

  describe 'authenticated first contact and observation ownership' do
    before { described_class.boot }

    def human_frame(identity:, exchange_id:, **metadata)
      Legion::Gaia::InputFrame.new(content: 'hello', channel_id: :cli,
                                   session_continuity_id: metadata.delete(:session_continuity_id),
                                   auth_context: { principal_id: identity, user_id: "native-#{identity}" },
                                   metadata: { source_type: :human_direct, exchange_id: exchange_id }.merge(metadata))
    end

    it 'preserves first-contact channel details and never reinforces one input twice' do
      frame = human_frame(identity: 'A', exchange_id: 'a1')
      expect(described_class.ingest(frame)[:ingested]).to be true
      entry = Legion::Gaia::BondRegistry.entry(identity: 'A')
      expect(entry).to include(last_channel: :cli, channel_identity: 'native-A')
      strength = entry[:strength]
      expect(described_class.ingest(frame)).to include(ingested: false, reason: :duplicate)
      described_class.observe_from_pipeline(identity: 'A', exchange_id: 'a1',
                                            caller: { requested_by: { type: :human, principal_id: 'A' } })
      expect(Legion::Gaia::BondRegistry.entry(identity: 'A')[:strength]).to eq(strength)
      expect(described_class.partner_observations.map { |observation| observation[:identity] }).to eq(['A'])
    end

    it 'observes an actual input even when its pipeline notification arrived first' do
      described_class.observe_from_pipeline(identity: 'A', exchange_id: 'a1',
                                            caller: { requested_by: { type: :human, principal_id: 'A' } })
      expect(described_class.ingest(human_frame(identity: 'A', exchange_id: 'a1'))[:ingested]).to be true
      expect(described_class.partner_observations.map do |observation|
        observation[:observed_exchange_id]
      end).to eq(['a1'])
    end

    it 'does not give another principal the first human session or queued growth' do
      first = described_class.ingest(human_frame(identity: 'A', exchange_id: 'a1', conversation_id: 'shared-label'))
      second = described_class.ingest(human_frame(identity: 'B', exchange_id: 'b1', conversation_id: 'shared-label',
                                                  session_continuity_id: first[:session_id]))
      expect(second[:session_id]).not_to eq(first[:session_id])
      described_class.send(:enqueue_growth_frame, message: 'A learned something', identity: 'A',
                                                  conversation_id: 'shared-label')
      expect(described_class.drain_growth_frames(identity: 'B', conversation_id: 'shared-label')).to eq([])
      expect(described_class.drain_growth_frames(identity: 'A', conversation_id: 'other')).to eq([])
      expect(described_class.drain_growth_frames(identity: 'A',
                                                 conversation_id: 'shared-label')).to eq(['A learned something'])
    end

    it 'does not borrow an unscoped response when feedback lacks correlation' do
      described_class.ingest(human_frame(identity: 'A', exchange_id: 'feedback', conversation_id: 'conversation'))
      observation = described_class.partner_observations.last
      expect(observation).to include(identity: 'A', conversation_id: 'conversation', observed_exchange_id: 'feedback')
      expect(observation.values_at(:exchange_id, :advisory_id, :in_reply_to)).to eq([nil, nil, nil])
      expect(Legion::Gaia::ResponseAttribution.status_for(identity: 'A')).to include(pending: 0, completed: 0)
    end

    it 'uses an explicit correction without requiring a scoped calibration provider' do
      Legion::Gaia::BondRegistry.register('A', bond: :partner, strength: 0.8, origin: :observed)
      synapse = Legion::Gaia::BehavioralSynapse.crystallize(
        identity: 'A', domain: 'communication', directive: 'Use long paragraphs', origin: 'explicit'
      )
      caller = { requested_by: { type: :human, principal_id: 'A' } }
      advisory = Legion::Gaia::Advisory.advise(caller: caller, conversation_id: 'c1', exchange_id: 'response')
      described_class.record_response_applied(
        advisory_id: advisory.fetch(:advisory_id), identity: 'A',
        applied: { behavioral_synapse_ids: [synapse[:id]], delivery_status: :returned,
                   conversation_id: 'c1', exchange_id: 'response' }
      )
      described_class.ingest(human_frame(
                               identity: 'A', exchange_id: 'correction', conversation_id: 'c1',
                               advisory_id: advisory[:advisory_id], response_exchange_id: 'response',
                               corrected_constraint: 'Use short bullets', domain: 'communication'
                             ))
      following = Legion::Gaia::Advisory.advise(caller: caller, conversation_id: 'c1', exchange_id: 'next')
      expect(following.fetch(:system_prompt)).to include('Use short bullets')
      expect(following.fetch(:system_prompt)).not_to include('Use long paragraphs')
      expect(Legion::Gaia::BehavioralSynapse.for(identity: 'A', domain: 'communication')[:confidence])
        .to be_within(0.0001).of(0.7)
    end
  end

  describe '.erase_attribution!' do
    it 'does not acknowledge durable erasure without a storage receipt' do
      allow(described_class).to receive(:apollo_local_store).and_return(nil)
      expect(described_class.erase_attribution!(identity: 'A')).to include(erased: false, durable: false)
    end
  end
end
