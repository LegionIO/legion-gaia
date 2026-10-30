# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::AuditObserver do
  subject(:observer) { described_class.instance }

  before do
    observer.reset!
    Legion::Gaia::BondRegistry.reset!
  end

  after { Legion::Gaia::BondRegistry.reset! }

  def audit_event(identity:, tool:, provider: :anthropic, **requested_by)
    { caller: { requested_by: { type: :human, principal_id: identity }.merge(requested_by) },
      routing: { provider: provider, model: 'model' }, tools_used: [{ name: tool }], timestamp: Time.now.utc }
  end

  it 'keeps interleaved human hints private rather than promoting them to global patterns' do
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))
    observer.process_event(audit_event(identity: 'B', tool: 'private_b', provider: :openai))
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))

    expect(observer.learned_data_for('A')[:tool_predictions].transform_values do |value|
      value[:count]
    end).to eq('private_a' => 2)
    expect(observer.learned_data_for('B')[:tool_predictions].keys).to eq(['private_b'])
    expect(observer.learned_data_for('B')[:routing_preference][:provider]).to eq(:openai)
    expect(observer.tool_patterns).to eq({})
  end

  it 'keys human hints by authenticated principal rather than a colliding display identity' do
    event = audit_event(identity: 'principal-a', tool: 'private')
    event[:caller][:requested_by][:identity] = 'same-name'
    observer.process_event(event)
    expect(observer.tool_patterns_for('principal-a').keys).to eq(['private'])
    expect(observer.user_preferences('same-name')).to eq({})
  end

  it 'does not let a service report overwrite a human routing preference' do
    observer.process_event(audit_event(identity: 'A', tool: 'human_tool'))
    observer.process_event(audit_event(identity: 'A', tool: 'service_tool', provider: :openai, type: :service))
    expect(observer.user_preferences('A')[:routing][:provider]).to eq(:anthropic)
    expect(observer.tool_patterns_for('A').keys).to eq(['human_tool'])
    expect(observer.tool_patterns.keys).to eq(['service_tool'])
  end

  it 'does not resurrect hints from late events after a lifecycle barrier' do
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))
    observer.process_event(audit_event(identity: 'B', tool: 'private_b'))
    Legion::Gaia::BondRegistry.set_bond_state('A', :terminating)
    observer.erase_partner!(identity: 'A')
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))
    expect(observer.learned_data_for('A')).to include(routing_preference: nil, tool_predictions: {})
    expect(observer.tool_patterns_for('B').keys).to eq(['private_b'])
  end

  it 'returns snapshots that cannot mutate another reader of learned data' do
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))
    snapshot = observer.learned_data_for('A')
    snapshot[:routing_preference][:provider] = :forged
    snapshot[:tool_predictions]['private_a'][:count] = 99
    expect(observer.user_preferences('A')[:routing][:provider]).to eq(:anthropic)
    expect(observer.tool_patterns_for('A')['private_a'][:count]).to eq(1)
  end

  it 'does not infer a human from an untyped legacy identity or bare id' do
    observer.process_event(caller: { requested_by: { identity: 'A', id: 'B' } }, routing: { provider: :openai })
    expect(observer.user_preferences('A')).to eq({})
    expect(observer.user_preferences('B')).to eq({})
  end

  it 'clears accumulated private and anonymous hints on reset' do
    observer.process_event(audit_event(identity: 'A', tool: 'private_a'))
    observer.process_event(tools_used: [{ name: 'public_tool' }], timestamp: Time.now.utc)
    observer.reset!
    expect(observer.learned_data_for('A')).to include(routing_preference: nil, tool_predictions: {})
    expect(observer.tool_patterns).to eq({})
  end
end
