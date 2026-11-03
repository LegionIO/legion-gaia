# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Routes do
  # Helper: builds a route evaluation context that mimics a Sinatra request env.
  # Captures the block registered via app.get and executes it on this context.
  def build_route_context(gaia_up:, params: {}, claims: { identity: 'human-a' })
    ctx = Object.new

    ctx.define_singleton_method(:gaia_available?) { gaia_up }
    ctx.define_singleton_method(:params) { params }
    request = double('request', env: { 'legion.auth' => claims })
    ctx.define_singleton_method(:request) { request }

    ctx.define_singleton_method(:json_response) do |data, status_code: 200|
      { status: status_code, body: data }
    end

    ctx.define_singleton_method(:json_error) do |code, message, status_code: 400|
      { status: status_code, error: { code: code, message: message } }
    end

    ctx.define_singleton_method(:halt) do |*args|
      throw :halt, args
    end

    ctx
  end

  def capture_ticks_block
    captured = nil
    fake_app = double('app')
    allow(fake_app).to receive(:get).with('/api/gaia/ticks') { |&blk| captured = blk }
    described_class.send(:register_ticks_route, fake_app)
    captured
  end

  def build_post_route_context(body:, env: {})
    ctx = build_route_context(gaia_up: true)
    request = double('request', body: StringIO.new(body), env: env)

    ctx.define_singleton_method(:request) { request }
    ctx.define_singleton_method(:params) { {} }
    ctx.define_singleton_method(:json_response) do |data, status_code: 200|
      { status: status_code, body: data }
    end
    ctx.define_singleton_method(:halt) do |*args|
      throw :halt, args
    end

    ctx
  end

  def capture_teams_webhook_block
    captured = nil
    fake_app = double('app')
    allow(fake_app).to receive(:post).with('/api/channels/teams/webhook') { |&blk| captured = blk }
    described_class.send(:register_teams_webhook_route, fake_app)
    captured
  end

  describe 'GET /api/gaia/ticks route block' do
    let(:ticks_block) { capture_ticks_block }

    context 'when GAIA is not started' do
      it 'halts with 503' do
        ctx = build_route_context(gaia_up: false)

        result = catch(:halt) { ctx.instance_exec(&ticks_block) }

        expect(result).not_to be_nil
        expect(result.first).to eq(503)
      end
    end

    context 'when GAIA is started' do
      let(:fake_history) do
        history = Legion::Gaia::TickHistory.new
        210.times do |i|
          history.record({ results: { "phase_#{i}": { elapsed_ms: i, status: :ok } } }, identity: 'human-a')
        end
        history
      end

      before do
        allow(Legion::Gaia).to receive(:tick_history).and_return(fake_history)
        allow(Legion::Gaia).to receive(:started?).and_return(true)
      end

      it 'returns events as JSON response' do
        ctx = build_route_context(gaia_up: true)
        result = ctx.instance_exec(&ticks_block)
        expect(result[:status]).to eq(200)
        expect(result[:body]).to have_key(:events)
      end

      it 'defaults to 50 events when no limit param is given' do
        ctx = build_route_context(gaia_up: true, params: {})
        result = ctx.instance_exec(&ticks_block)
        expect(result[:body][:events].size).to eq(50)
      end

      it 'clamps limit to MAX_ENTRIES (200) when a larger value is requested' do
        ctx = build_route_context(gaia_up: true, params: { limit: '9999' })
        result = ctx.instance_exec(&ticks_block)
        expect(result[:body][:events].size).to eq(Legion::Gaia::TickHistory::MAX_ENTRIES)
      end

      it 'clamps limit to 1 when 0 or negative is requested' do
        ctx = build_route_context(gaia_up: true, params: { limit: '0' })
        result = ctx.instance_exec(&ticks_block)
        expect(result[:body][:events].size).to eq(1)
      end

      it 'returns empty events array when tick_history is nil' do
        allow(Legion::Gaia).to receive(:tick_history).and_return(nil)
        ctx = build_route_context(gaia_up: true)
        result = ctx.instance_exec(&ticks_block)
        expect(result[:body][:events]).to eq([])
      end

      it 'rejects anonymous access rather than returning all human history' do
        ctx = build_route_context(gaia_up: true, claims: nil)
        expect(catch(:halt) { ctx.instance_exec(&ticks_block) }.first).to eq(401)
      end

      it 'excludes another principal history' do
        fake_history.record({ results: { secret: { status: :completed } } }, identity: 'human-b')
        ctx = build_route_context(gaia_up: true, claims: { identity: 'human-b' })
        events = ctx.instance_exec(&ticks_block)[:body][:events]
        expect(events.size).to eq(1)
        expect(events.first[:identity]).to eq('human-b')
      end
    end
  end

  describe 'POST /api/channels/teams/webhook route block' do
    let(:webhook_block) { capture_teams_webhook_block }
    let(:activity) do
      {
        'type' => 'message',
        'id' => 'activity-1',
        'text' => 'hello gaia',
        'from' => { 'id' => 'user-1', 'name' => 'Esity', 'aadObjectId' => 'oid-1' },
        'conversation' => { 'id' => 'conv-1' },
        'recipient' => { 'id' => 'bot-1' }
      }
    end
    let(:input_frame) do
      Legion::Gaia::InputFrame.new(
        id: 'frame-1',
        content: 'hello gaia',
        channel_id: :teams,
        auth_context: { aad_object_id: 'oid-1', identity: 'oid-1' },
        metadata: { source_type: :human_direct, direct_address: true }
      )
    end
    let(:adapter) { instance_double(Legion::Gaia::Channels::TeamsAdapter, app_id: 'app-id') }

    before do
      allow(Legion::Gaia::Routes).to receive(:teams_adapter).and_return(adapter)
      allow(adapter).to receive(:validate_inbound).with('verified-token').and_return({ valid: true })
    end

    it 'routes webhook frames through Gaia.ingest' do
      allow(adapter).to receive(:translate_inbound)
        .with(hash_including('type' => 'message', 'text' => 'hello gaia'))
        .and_return(input_frame)
      allow(Legion::Gaia).to receive(:sensory_buffer).and_return(instance_double(Legion::Gaia::SensoryBuffer))

      expect(Legion::Gaia).to receive(:ingest).with(input_frame)
      expect(Legion::Gaia.sensory_buffer).not_to receive(:push)

      ctx = build_post_route_context(body: Legion::JSON.dump(activity),
                                     env: { 'HTTP_AUTHORIZATION' => 'Bearer verified-token' })
      result = ctx.instance_exec(&webhook_block)

      expect(result[:status]).to eq(200)
      expect(result[:body]).to eq({ status: 'accepted', frame_id: 'frame-1' })
    end

    it 'halts with 503 when teams adapter is unavailable' do
      allow(Legion::Gaia::Routes).to receive(:teams_adapter).and_return(nil)

      ctx = build_post_route_context(body: Legion::JSON.dump(activity))
      result = catch(:halt) { ctx.instance_exec(&webhook_block) }

      expect(result).not_to be_nil
      expect(result.first).to eq(503)
    end

    it 'halts when webhook authentication fails' do
      auth_adapter = instance_double(Legion::Gaia::Channels::TeamsAdapter, app_id: 'app-id')
      allow(Legion::Gaia::Routes).to receive(:teams_adapter).and_return(auth_adapter)

      ctx = build_post_route_context(body: Legion::JSON.dump(activity))
      result = catch(:halt) { ctx.instance_exec(&webhook_block) }

      expect(result).not_to be_nil
      expect(result.first).to eq(401)
    end
  end

  describe 'POST /api/gaia/ingest identity boundary' do
    let(:ingest_block) do
      captured = nil
      app = double('app')
      allow(app).to receive(:post).with('/api/gaia/ingest') { |&block| captured = block }
      described_class.send(:register_ingest_route, app)
      captured
    end

    before do
      Legion::Gaia::BondRegistry.reset!
      store = double('PrivateStore', query_by_tags: { success: true, results: [] }, upsert: { success: true })
      allow(Legion::Gaia).to receive(:apollo_local_store).and_return(store)
      Legion::Gaia.boot
    end

    after do
      Legion::Gaia.shutdown
      Legion::Gaia::BondRegistry.reset!
      Legion::Gaia::ResponseAttribution.reset!
    end

    it 'queues work for the verified principal, never the supplied victim or unverified session' do
      body = Legion::JSON.dump(content: 'hello', identity: 'victim', conversation_id: 'conversation-a',
                               exchange_id: 'exchange-a', session_continuity_id: 'session-a')
      ctx = build_post_route_context(body: body, env: { 'legion.auth' => { principal_id: 'human-a' } })
      result = ctx.instance_exec(&ingest_block)
      expect(result[:body]).to include(ingested: true, status: 'accepted')
      expect(result[:body][:session_id]).not_to eq('session-a')
      expect(Legion::Gaia.sensory_buffer.drain.first).to include(identity: 'human-a',
                                                                 conversation_id: 'conversation-a',
                                                                 exchange_id: 'exchange-a')
      expect(Legion::Gaia::BondRegistry.entry(identity: 'victim')).to be_nil
    end

    it 'does not treat an unauthenticated body identity as trusted' do
      ctx = build_post_route_context(body: Legion::JSON.dump(content: 'hello', identity: 'victim'))
      expect(ctx.instance_exec(&ingest_block)[:body][:ingested]).to be true
      expect(Legion::Gaia.sensory_buffer.drain.first[:identity]).to be_nil
      expect(Legion::Gaia::BondRegistry.entry(identity: 'victim')).to be_nil
    end

    it 'keeps correction and forecast evidence under the authenticated owner' do
      supplied = {
        identity: 'victim', principal_id: 'victim', source_type: 'system',
        advisory_id: 'advisory-a', in_reply_to: 'response-a', response_exchange_id: 'reply-a',
        corrected_constraint: 'ask before sending', domain: 'notifications',
        prediction_request: {
          domain: 'work', description: 'complete task', expected_outcome: 'done', identity: 'victim'
        }
      }
      ctx = build_post_route_context(body: Legion::JSON.dump(content: 'correction', metadata: supplied),
                                     env: { 'legion.auth' => { identity: 'human-a' } })
      expect(ctx.instance_exec(&ingest_block)[:body][:ingested]).to be true
      observation = Legion::Gaia.partner_observations.last
      expect(observation).to include(identity: 'human-a', advisory_id: 'advisory-a', in_reply_to: 'response-a',
                                     exchange_id: 'reply-a', corrected_constraint: 'ask before sending')
      signal = Legion::Gaia.sensory_buffer.drain.first
      expect(signal).to include(identity: 'human-a', source_type: :human_direct)
      expect(signal.dig(:metadata, :prediction_request)).to eq(supplied[:prediction_request].except(:identity))
    end

    it 'does not promote anonymous body claims into feedback evidence' do
      ctx = build_post_route_context(body: Legion::JSON.dump(content: 'claim', advisory_id: 'advisory-a',
                                                             cognitive_outcome: { prediction_id: 'prediction-a',
                                                                                  confirmation: 'human_observed' }))
      result = ctx.instance_exec(&ingest_block)
      expect(result[:body]).not_to have_key(:cognitive_outcome)
      expect(Legion::Gaia.partner_observations).to eq([])
    end

    it 'reports blocked ingestion rather than claiming acceptance' do
      Legion::Gaia::BondRegistry.set_bond_state('human-a', :revoked)
      ctx = build_post_route_context(body: Legion::JSON.dump(content: 'do not ingest'),
                                     env: { 'legion.auth' => { principal_id: 'human-a' } })
      result = ctx.instance_exec(&ingest_block)
      expect(result).to include(status: 409)
      expect(result[:body]).to include(ingested: false, status: 'rejected', reason: :identity_blocked)
      expect(Legion::Gaia.sensory_buffer.drain).to eq([])
    end
  end

  describe 'private relationship route ownership' do
    it 'rejects a different authenticated principal for disclosure and erasure' do
      [[:register_partner_report_route, :get, '/api/gaia/partner/:identity/report'],
       [:register_bond_terminate_route, :delete, '/api/gaia/bond/:identity']].each do |registration, verb, path|
        captured = nil
        app = double('app')
        allow(app).to receive(verb).with(path) { |&block| captured = block }
        described_class.send(registration, app)
        ctx = build_route_context(gaia_up: true, params: { identity: 'human-b' })
        request = double('request', env: { 'legion.auth' => { identity: 'human-a' } })
        ctx.define_singleton_method(:request) { request }
        expect(catch(:halt) { ctx.instance_exec(&captured) }.first).to eq(403)
      end
    end
  end

  describe 'GET /api/gaia/status scope' do
    it 'uses verified claims rather than a requested identity' do
      captured = nil
      app = double('app')
      allow(app).to receive(:get).with('/api/gaia/status') { |&block| captured = block }
      described_class.send(:register_status_route, app)
      ctx = build_route_context(gaia_up: true, params: { identity: 'victim' }, claims: { identity: 'human-a' })
      expect(Legion::Gaia).to receive(:status).with(identity: 'human-a').and_return({ started: true })
      expect(ctx.instance_exec(&captured)[:body]).to eq({ started: true })
    end
  end
end
