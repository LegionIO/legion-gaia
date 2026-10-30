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
        stub_const('Legion::Logging', logging_stub)
        store = double('PrivateStore', query_by_tags: { success: true, results: [] }, upsert: { success: true })
        allow(Legion::Gaia).to receive(:apollo_local_store).and_return(store)
        Legion::Gaia.boot
      end
      after do
        Legion::Gaia.shutdown
        Legion::Gaia::BondRegistry.reset!
      end

      it 'ingests the payload into GAIA' do
        result = bridge.ingest_from_payload(payload)
        expect(result[:ingested]).to be true
        expect(result[:buffer_depth]).to be >= 1
      end

      it 'preserves transport ownership, correlation, source, and original receive time' do
        received_at = Time.utc(2026, 10, 29, 12, 0, 0)
        transported = Legion::JSON.load(Legion::JSON.dump(payload.merge(
                                                            principal_id: 'principal-a',
                                                            received_at: received_at.iso8601(9),
                                                            session_continuity_id: 'session-a',
                                                            metadata: { source_type: :human_direct,
                                                                        conversation_id: 'conversation-a',
                                                                        exchange_id: 'exchange-a' }
                                                          )))
        result = bridge.ingest_from_payload(transported)
        expect(result[:ingested]).to be true
        signal = Legion::Gaia.sensory_buffer.drain.first
        expect(signal).to include(identity: 'principal-a', frame_id: 'frame-1', received_at: received_at,
                                  conversation_id: 'conversation-a', exchange_id: 'exchange-a',
                                  source_type: :human_direct)
      end
    end

    it 'returns invalid_frame for broken payload' do
      result = bridge.ingest_from_payload({ content: nil, channel_id: nil })
      expect(result[:ingested]).to be false
      expect(result[:reason]).to eq(:gaia_not_started)
    end
  end
end
