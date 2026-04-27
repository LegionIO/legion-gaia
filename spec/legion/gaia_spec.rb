# frozen_string_literal: true

require 'timeout'

RSpec.describe Legion::Gaia do
  before do
    stub_const('Legion::Logging', logging_stub)
  end

  after do
    described_class.shutdown if described_class.started?
  end

  describe '.boot' do
    it 'starts GAIA and sets started? to true' do
      described_class.boot
      expect(described_class.started?).to be true
    end

    it 'creates a sensory buffer' do
      described_class.boot
      expect(described_class.sensory_buffer).to be_a(Legion::Gaia::SensoryBuffer)
    end

    it 'creates a registry' do
      described_class.boot
      expect(described_class.registry).to be_a(Legion::Gaia::Registry)
    end

    context 'when Apollo Local is available on boot (Fix 1 + Fix 2)' do
      let(:mock_store) do
        double('ApolloLocal', started?: true).tap do |s|
          allow(s).to receive(:query).and_return({ success: false })
          allow(s).to receive(:upsert)
        end
      end

      before do
        Legion::Gaia::TrackerPersistence.reset!
        stub_const('Legion::Apollo::Local', mock_store)
        allow(Legion::Gaia::TrackerPersistence).to receive(:hydrate_all)
        allow(Legion::Gaia::BondRegistry).to receive(:hydrate_from_apollo)
        # Prevent flush_all on shutdown from trying real tracker objects
        allow(Legion::Gaia::TrackerPersistence).to receive(:flush_all)
      end

      it 'calls TrackerPersistence.hydrate_all with the apollo local store' do
        described_class.boot
        expect(Legion::Gaia::TrackerPersistence).to have_received(:hydrate_all).with(store: mock_store)
      end

      it 'calls BondRegistry.hydrate_from_apollo with the apollo local store' do
        described_class.boot
        expect(Legion::Gaia::BondRegistry).to have_received(:hydrate_from_apollo).with(store: mock_store)
      end
    end

    context 'when Apollo Local is not available on boot' do
      it 'does not call TrackerPersistence.hydrate_all' do
        expect(Legion::Gaia::TrackerPersistence).not_to receive(:hydrate_all)
        described_class.boot
      end

      it 'does not call BondRegistry.hydrate_from_apollo' do
        expect(Legion::Gaia::BondRegistry).not_to receive(:hydrate_from_apollo)
        described_class.boot
      end
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

    context 'when lex-tick is unavailable' do
      let(:logger) { double('Logger').as_null_object }

      before { described_class.boot }

      it 'logs the warning on the first heartbeat' do
        msg = '[gaia] lex-tick not available, will retry next heartbeat'
        allow(described_class).to receive(:log).and_return(logger)
        expect(logger).to receive(:warn).with(msg).once
        described_class.heartbeat
      end

      it 'does not log the warning on subsequent heartbeats' do
        allow(described_class).to receive(:log).and_return(logger)
        described_class.heartbeat
        expect(logger).not_to receive(:warn)
        described_class.heartbeat
        described_class.heartbeat
      end

      it 'logs the warning again after tick becomes available then unavailable again' do
        registry = described_class.registry
        mock_tick = instance_double('TickHost')
        allow(mock_tick).to receive(:execute_tick).and_return({ results: {} })
        allow(mock_tick).to receive(:last_tick_result=)

        # First unavailability: warning fires once
        allow(described_class).to receive(:log).and_return(logger)
        expect(logger).to receive(:warn).once
        described_class.heartbeat

        # Tick becomes available: resets the warned flag
        allow(registry).to receive(:tick_host).and_return(mock_tick)
        allow(registry).to receive(:phase_handlers).and_return({})
        described_class.heartbeat

        # Tick goes unavailable again: warning fires again
        allow(registry).to receive(:tick_host).and_return(nil)
        msg = '[gaia] lex-tick not available, will retry next heartbeat'
        expect(logger).to receive(:warn).with(msg).once
        described_class.heartbeat
      end
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

    it 'memoizes quiescing phase wrappers for the active handler map' do
      described_class.boot
      handlers = { prediction_engine: ->(**) { { invoked: true } } }

      first = described_class.send(:quiescing_phase_handlers, handlers)
      second = described_class.send(:quiescing_phase_handlers, handlers)
      third = described_class.send(:quiescing_phase_handlers, handlers.dup)

      expect(second).to equal(first)
      expect(third).not_to equal(first)
    end
  end

  describe '.heartbeat notification gate feeds' do
    before { described_class.boot }

    context 'when tick host is available' do
      let(:mock_tick) { instance_double('TickHost') }

      before do
        allow(mock_tick).to receive(:execute_tick).and_return({
                                                                results: { emotional_evaluation: { valence: {
                                                                  urgency: 0.6, novelty: 0.4, importance: 0.8
                                                                } } }
                                                              })
        allow(mock_tick).to receive(:last_tick_result=)
        allow(described_class.registry).to receive(:tick_host).and_return(mock_tick)
        allow(described_class.registry).to receive(:phase_handlers).and_return({})
      end

      it 'feeds arousal to the notification gate' do
        gate = described_class.output_router.notification_gate
        expect(gate).to receive(:update_behavioral).with(arousal: be_between(0.0, 1.0))
        described_class.heartbeat
      end

      it 'calls process_delayed on the output router' do
        expect(described_class.output_router).to receive(:process_delayed)
        described_class.heartbeat
      end

      it 'computes arousal as mean of urgency, novelty, importance' do
        gate = described_class.output_router.notification_gate
        # (0.6 + 0.4 + 0.8) / 3.0 = 0.6
        expect(gate).to receive(:update_behavioral).with(arousal: be_within(0.01).of(0.6))
        described_class.heartbeat
      end
    end

    context 'when tick result has no valence' do
      let(:mock_tick) { instance_double('TickHost') }

      before do
        allow(mock_tick).to receive(:execute_tick).and_return({ results: {} })
        allow(mock_tick).to receive(:last_tick_result=)
        allow(described_class.registry).to receive(:tick_host).and_return(mock_tick)
        allow(described_class.registry).to receive(:phase_handlers).and_return({})
      end

      it 'does not feed arousal to the notification gate' do
        gate = described_class.output_router.notification_gate
        expect(gate).not_to receive(:update_behavioral)
        described_class.heartbeat
      end

      it 'still calls process_delayed' do
        expect(described_class.output_router).to receive(:process_delayed)
        described_class.heartbeat
      end
    end
  end

  describe '.heartbeat partner absence' do
    before { described_class.boot }

    let(:mock_tick) { instance_double('TickHost') }

    before do
      allow(mock_tick).to receive(:execute_tick).and_return({ results: {} })
      allow(mock_tick).to receive(:last_tick_result=)
      allow(described_class.registry).to receive(:tick_host).and_return(mock_tick)
    end

    context 'when prediction_engine phase is wired' do
      before do
        allow(described_class.registry).to receive(:phase_handlers)
          .and_return({ prediction_engine: ->(**) {} })
      end

      it 'increments absence counter when no partner observations' do
        described_class.heartbeat
        misses = described_class.instance_variable_get(:@partner_absence_misses)
        expect(misses).to eq(1)
      end

      it 'accumulates consecutive misses' do
        3.times { described_class.heartbeat }
        misses = described_class.instance_variable_get(:@partner_absence_misses)
        expect(misses).to eq(3)
      end

      it 'resets counter when partner is observed' do
        described_class.heartbeat
        described_class.heartbeat

        described_class.instance_variable_set(:@partner_observations,
                                              [{ bond_role: :partner, identity: 'test' }])
        described_class.heartbeat

        misses = described_class.instance_variable_get(:@partner_absence_misses)
        expect(misses).to eq(0)
      end

      it 'injects absence valence into last_valences' do
        described_class.heartbeat
        valences = described_class.last_valences
        expect(valences).to be_a(Array)
        expect(valences.last[:urgency]).to eq(0.2)
        expect(valences.last[:familiarity]).to eq(0.8)
      end

      it 'scales importance logarithmically with consecutive misses' do
        described_class.heartbeat
        low_importance = described_class.last_valences.last[:importance]

        20.times { described_class.heartbeat }
        high_importance = described_class.last_valences.last[:importance]

        expect(high_importance).to be > low_importance
      end

      it 'caps importance at 0.7' do
        100.times { described_class.heartbeat }
        importance = described_class.last_valences.last[:importance]
        expect(importance).to be <= 0.7
      end

      context 'when action_selection is also wired and absence exceeds pattern' do
        let(:attachment_runner) { instance_double('AttachmentRunner') }

        before do
          allow(described_class.registry).to receive(:phase_handlers)
            .and_return({ prediction_engine: ->(**) {}, action_selection: ->(**) {} })
          allow(described_class.registry).to receive(:runner_instances)
            .and_return({ Social_Attachment: attachment_runner })
          allow(attachment_runner).to receive(:reflect_on_bonds)
            .with(tick_results: {}, bond_summary: {})
            .and_return({ partner_bond: { absence_exceeds_pattern: true } })
        end

        it 'queues an internal absence signal after sustained misses' do
          5.times { described_class.heartbeat }

          expect(described_class.sensory_buffer.size).to eq(1)
          signal = described_class.sensory_buffer.drain.first
          expect(signal[:source_type]).to eq(:partner_absence)
          expect(signal[:salience]).to eq(0.75)
        end

        it 'respects the absence signal cooldown' do
          10.times { described_class.heartbeat }
          expect(attachment_runner).to have_received(:reflect_on_bonds).once
        end
      end
    end

    context 'when prediction_engine phase is not wired' do
      before do
        allow(described_class.registry).to receive(:phase_handlers).and_return({})
      end

      it 'does not increment absence counter' do
        described_class.heartbeat
        misses = described_class.instance_variable_get(:@partner_absence_misses)
        expect(misses).to eq(0)
      end

      it 'does not inject absence valence' do
        described_class.heartbeat
        valences = described_class.last_valences
        expect(valences).to be_nil
      end
    end

    context 'when non-partner observations arrive' do
      before do
        allow(described_class.registry).to receive(:phase_handlers)
          .and_return({ prediction_engine: ->(**) {} })
        described_class.instance_variable_set(:@partner_observations,
                                              [{ bond_role: :unknown, identity: 'visitor' }])
      end

      it 'still increments absence counter' do
        described_class.heartbeat
        misses = described_class.instance_variable_get(:@partner_absence_misses)
        expect(misses).to eq(1)
      end
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

  describe '.settings' do
    it 'returns default settings hash' do
      settings = described_class.settings
      expect(settings).to be_a(Hash)
      expect(settings[:heartbeat_interval]).to eq(1)
      expect(settings[:channels]).to have_key(:cli)
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

  describe '.respond with agent_bridge' do
    it 'publishes through agent_bridge when available' do
      described_class.boot
      mock_bridge = instance_double(Legion::Gaia::Router::AgentBridge, started?: true)
      allow(mock_bridge).to receive(:publish_output).and_return({ published: true })
      allow(mock_bridge).to receive(:stop)
      described_class.instance_variable_set(:@agent_bridge, mock_bridge)

      result = described_class.respond(content: 'test', channel_id: :cli)
      expect(result[:published]).to be true
      expect(mock_bridge).to have_received(:publish_output)
    end
  end

  describe '.ingest with partner observation' do
    before do
      allow(Legion::Gaia::BondRegistry).to receive(:bond).and_return(:unknown)

      described_class.instance_variable_set(:@started, true)
      described_class.instance_variable_set(:@sensory_buffer, Legion::Gaia::SensoryBuffer.new)
      described_class.instance_variable_set(:@session_store, Legion::Gaia::SessionStore.new)
      described_class.instance_variable_set(:@partner_observations, [])
    end

    it 'populates partner_observations buffer from auth_context identity' do
      frame = Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :cli,
        auth_context: { identity: 'esity' }
      )
      described_class.ingest(frame)

      obs = described_class.partner_observations
      expect(obs.size).to eq(1)
      expect(obs.first[:identity]).to eq('esity')
      expect(obs.first[:bond_role]).to eq(:unknown)
    end

    it 'skips observation for anonymous identity' do
      frame = Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :cli,
        auth_context: {}
      )
      described_class.ingest(frame)

      expect(described_class.partner_observations).to be_empty
    end

    it 'detects partner role from BondRegistry' do
      allow(Legion::Gaia::BondRegistry).to receive(:bond).with('esity').and_return(:partner)

      frame = Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :teams,
        auth_context: { identity: 'esity' }
      )
      described_class.ingest(frame)

      obs = described_class.partner_observations.first
      expect(obs[:bond_role]).to eq(:partner)
      expect(obs[:channel]).to eq(:teams)
    end

    it 'extracts identity from aad_object_id fallback' do
      frame = Legion::Gaia::InputFrame.new(
        content: 'hello',
        channel_id: :teams,
        auth_context: { aad_object_id: 'aad-123', user_name: 'Test' }
      )
      described_class.ingest(frame)

      obs = described_class.partner_observations
      expect(obs.size).to eq(1)
      expect(obs.first[:identity]).to eq('aad-123')
    end
  end

  describe 'VERSION' do
    it 'has a version number' do
      expect(Legion::Gaia::VERSION).not_to be_nil
    end
  end
end
