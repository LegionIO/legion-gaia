# frozen_string_literal: true

RSpec.describe Legion::Gaia do
  before do
    stub_const('Legion::Logging', Module.new do
      def self.debug(_msg); end
      def self.info(_msg); end
      def self.warn(_msg); end
      def self.error(_msg); end
    end)
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
      before { described_class.boot }

      it 'logs the warning on the first heartbeat' do
        msg = '[gaia] lex-tick not available, will retry next heartbeat'
        expect(described_class).to receive(:log_warn).with(msg).once
        described_class.heartbeat
      end

      it 'does not log the warning on subsequent heartbeats' do
        described_class.heartbeat
        expect(described_class).not_to receive(:log_warn)
        described_class.heartbeat
        described_class.heartbeat
      end

      it 'logs the warning again after tick becomes available then unavailable again' do
        registry = described_class.registry
        mock_tick = instance_double('TickHost')
        allow(mock_tick).to receive(:execute_tick).and_return({ results: {} })
        allow(mock_tick).to receive(:last_tick_result=)

        # First unavailability: warning fires once
        expect(described_class).to receive(:log_warn).once
        described_class.heartbeat

        # Tick becomes available: resets the warned flag
        allow(registry).to receive(:tick_host).and_return(mock_tick)
        allow(registry).to receive(:phase_handlers).and_return({})
        described_class.heartbeat

        # Tick goes unavailable again: warning fires again
        allow(registry).to receive(:tick_host).and_return(nil)
        msg = '[gaia] lex-tick not available, will retry next heartbeat'
        expect(described_class).to receive(:log_warn).with(msg).once
        described_class.heartbeat
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

  describe 'VERSION' do
    it 'has a version number' do
      expect(Legion::Gaia::VERSION).not_to be_nil
    end
  end
end
