# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Routes do
  it 'is a module' do
    expect(Legion::Gaia::Routes).to be_a(Module)
  end

  it 'responds to registered' do
    expect(Legion::Gaia::Routes).to respond_to(:registered)
  end

  it 'has a register_ticks_route private class method' do
    expect(described_class.private_methods).to include(:register_ticks_route)
  end

  describe '.register_ticks_route' do
    let(:app) { double('SinatraApp') }

    it 'registers GET /api/gaia/ticks on the app' do
      expect(app).to receive(:get).with('/api/gaia/ticks')
      described_class.send(:register_ticks_route, app)
    end
  end

  # Helper: builds a route evaluation context that mimics a Sinatra request env.
  # Captures the block registered via app.get and executes it on this context.
  def build_route_context(gaia_up:, params: {})
    ctx = Object.new

    ctx.define_singleton_method(:gaia_available?) { gaia_up }
    ctx.define_singleton_method(:params) { params }

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

  def build_post_route_context(body:)
    ctx = Object.new
    request = double('request', body: StringIO.new(body), env: {})

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
          history.record({ results: { "phase_#{i}": { elapsed_ms: i, status: :ok } } })
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
    let(:adapter) { instance_double(Legion::Gaia::Channels::TeamsAdapter, app_id: nil) }

    before do
      allow(Legion::Gaia::Routes).to receive(:teams_adapter).and_return(adapter)
    end

    it 'routes webhook frames through Gaia.ingest' do
      allow(adapter).to receive(:translate_inbound)
        .with(hash_including('type' => 'message', 'text' => 'hello gaia'))
        .and_return(input_frame)
      allow(Legion::Gaia).to receive(:sensory_buffer).and_return(instance_double(Legion::Gaia::SensoryBuffer))

      expect(Legion::Gaia).to receive(:ingest).with(input_frame)
      expect(Legion::Gaia.sensory_buffer).not_to receive(:push)

      ctx = build_post_route_context(body: Legion::JSON.dump(activity))
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
end
