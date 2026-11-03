# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Advisory do
  before do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
    Legion::Gaia::AuditObserver.instance.reset!
    allow(Legion::Gaia).to receive(:started?).and_return(true)
    allow(Legion::Gaia).to receive(:registry).and_return(nil)
    allow(Legion::Gaia).to receive(:tick_result_for).and_return(nil)
    allow(Legion::Gaia).to receive(:drain_growth_frames).and_return([])
  end

  after do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::ResponseAttribution.reset!
    Legion::Gaia::AuditObserver.instance.reset!
  end

  def advise(identity: 'alice', conversation_id: 'c1', **)
    described_class.advise(caller: { requested_by: { principal_id: identity, identity: 'display-name', type: :human } },
                           conversation_id: conversation_id, **)
  end

  it 'leaves ordinary inference unpersonalized for anonymous or stopped calls' do
    expect(described_class.advise(caller: {}, conversation_id: 'c1')).to eq({})
    allow(Legion::Gaia).to receive(:started?).and_return(false)
    expect(advise).to be_nil
  end

  it 'does not use a global latest tick or another humans valence' do
    allow(Legion::Gaia).to receive(:last_valences).and_return([-0.9])
    global_tick = { results: { prediction_engine: { predictions: [{ tool: 'bob_secret', confidence: 1.0 }] } } }
    allow(Legion::Gaia).to receive(:registry).and_return(double(tick_host: double(last_tick_result: global_tick)))
    expect(advise).to eq({})
  end

  it 'selects only the requesting human and conversation tick data' do
    allow(Legion::Gaia).to receive(:tick_result_for).with(identity: 'alice', conversation_id: 'c1').and_return(
      results: { prediction_engine: { predictions: [{ 'tool' => 'read_file', 'confidence' => 0.9 }] },
                 emotional_evaluation: { valence: 0.4 },
                 post_tick_reflection: { routing_preference: { 'provider' => :anthropic, model: :sonnet } } }
    )
    result = advise
    expect(result).to include(tool_hint: ['read_file'], valence: 0.4,
                              routing_hint: { provider: 'anthropic', model: 'sonnet' })
    expect(advise(identity: 'bob')).to eq({})
    expect(advise(conversation_id: 'other')).to eq({})
  end

  it 'ignores a tick explicitly correlated to a different exchange' do
    allow(Legion::Gaia).to receive(:tick_result_for).and_return(
      exchange_id: 'old', results: { sensory_processing: { suppressed: ['search'] } }
    )
    expect(advise(exchange_id: 'new')).to eq({})
  end

  it 'returns selected provenance without claiming those adjustments were applied' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.8)
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'alice', domain: 'brevity', directive: 'Keep it concise',
                                                origin: 'explicit')
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'bob', domain: 'tone', directive: 'Bob private phrase',
                                                origin: 'explicit')
    result = advise
    expect(result[:advisory_id]).to be_a(String)
    expect(result[:system_prompt]).to include('Keep it concise')
    expect(result[:system_prompt]).not_to include('Bob private phrase')
    selected = result[:selected]
    expect(selected[:sources]).to include(hash_including(domain: 'brevity', type: :synapse,
                                                         advisory_type: :verbosity_adjustment))
    expect(selected[:behavioral_synapse_ids]).to eq([Legion::Gaia::BehavioralSynapse.for(identity: 'alice',
                                                                                         domain: 'brevity')[:id]])
    expect(Legion::Gaia::ResponseAttribution.status_for(identity: 'alice')).to include(pending: 0, completed: 0)
    expect(result).not_to have_key(:applied)
  end

  it 'drains growth only for the requesting human and conversation' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.8)
    allow(Legion::Gaia).to receive(:drain_growth_frames)
      .with(identity: 'alice', conversation_id: 'c1').and_return(['Alice learned brevity'])
    allow(Legion::Gaia).to receive(:drain_growth_frames)
      .with(identity: 'bob', conversation_id: 'c1').and_return(['Bob private growth'])
    expect(advise[:system_prompt]).to include('Alice learned brevity')
    expect(advise[:system_prompt]).not_to include('Bob private growth')
    expect(advise(conversation_id: 'c2')[:system_prompt]).not_to include('Alice learned brevity')
  end

  it 'bounds selected content even when stored directives or prediction lists are large' do
    Legion::Gaia::BondRegistry.register('alice', bond: :partner, strength: 0.8)
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'alice', domain: 'tone', directive: 'x' * 100_000,
                                                origin: 'explicit')
    allow(Legion::Gaia).to receive(:tick_result_for).and_return(
      results: { prediction_engine: { predictions: 100.times.map do |index|
        { tool: "tool_#{index}", confidence: 0.8 }
      end } }
    )
    result = advise
    expect(result[:system_prompt].length).to be < 2000
    expect(result[:tool_hint]).to eq(%w[tool_0 tool_1 tool_2 tool_3 tool_4])
  end

  it 'keeps learned routing identity-scoped when no current tick exists' do
    Legion::Gaia::AuditObserver.instance.process_event(
      caller: { requested_by: { principal_id: 'alice', identity: 'display-name', type: :human } },
      routing: { provider: :claude, model: 'opus' },
      tokens: {}, tools_used: [], timestamp: Time.now
    )
    expect(advise[:routing_hint]).to include(provider: 'claude')
    expect(advise(identity: 'bob')).to eq({})
    nonhuman = { requested_by: { principal_id: 'alice', type: :service } }
    expect(described_class.advise(caller: nonhuman)).to eq({})
  end
end
