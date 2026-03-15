# frozen_string_literal: true

RSpec.describe Legion::Gaia::Router::AgentBridge do
  subject(:bridge) { described_class.new(worker_id: 'worker-1') }

  describe '#initialize' do
    it 'stores worker_id' do
      expect(bridge.worker_id).to eq('worker-1')
    end

    it 'starts in stopped state' do
      expect(bridge.started?).to be false
    end
  end

  describe '#start / #stop' do
    it 'tracks started state' do
      bridge.start
      expect(bridge.started?).to be true
      bridge.stop
      expect(bridge.started?).to be false
    end
  end

  describe '#publish_output' do
    let(:frame) { Legion::Gaia::OutputFrame.new(content: 'hello', channel_id: :teams) }

    it 'returns not_started when bridge not started' do
      result = bridge.publish_output(frame)
      expect(result[:published]).to be false
      expect(result[:reason]).to eq(:not_started)
    end

    it 'returns no_transport when transport not available' do
      bridge.start
      result = bridge.publish_output(frame)
      expect(result[:published]).to be false
      expect(result[:reason]).to eq(:no_transport)
    end
  end

  describe '#ingest_from_payload' do
    let(:payload) do
      {
        id: 'frame-1',
        content: 'hello from router',
        content_type: :text,
        channel_id: :teams,
        auth_context: { identity: 'user-1' },
        metadata: {}
      }
    end

    it 'returns gaia_not_started when GAIA not booted' do
      result = bridge.ingest_from_payload(payload)
      expect(result[:ingested]).to be false
      expect(result[:reason]).to eq(:gaia_not_started)
    end

    context 'with GAIA booted' do
      before do
        stub_const('Legion::Logging', Module.new do
          def self.debug(_msg); end
          def self.info(_msg); end
          def self.warn(_msg); end
          def self.error(_msg); end
        end)
        Legion::Gaia.boot
      end
      after { Legion::Gaia.shutdown }

      it 'ingests the payload into GAIA' do
        result = bridge.ingest_from_payload(payload)
        expect(result[:ingested]).to be true
        expect(result[:buffer_depth]).to be >= 1
      end
    end

    it 'returns invalid_frame for broken payload' do
      result = bridge.ingest_from_payload({ content: nil, channel_id: nil })
      expect(result[:ingested]).to be false
      expect(result[:reason]).to eq(:gaia_not_started)
    end
  end
end
