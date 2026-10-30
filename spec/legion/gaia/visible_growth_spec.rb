# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::VisibleGrowth do
  before do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    allow(Legion::Gaia).to receive(:registry).and_return(nil)
  end

  after do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  it 'deduplicates a milestone only for the same human, domain and tier transition' do
    arguments = { identity: 'alice', domain: 'tone', old_mode: :observe, new_mode: :filter }
    expect(described_class.milestone_acknowledgment(**arguments)).to be_a(String)
    expect(described_class.milestone_acknowledgment(**arguments)).to be_nil
    expect(described_class.milestone_acknowledgment(**arguments, identity: 'bob')).to be_a(String)
    expect(described_class.milestone_acknowledgment(**arguments, domain: 'format')).to be_a(String)
    expect(described_class.milestone_acknowledgment(**arguments, old_mode: :filter,
                                                                 new_mode: :transform)).to be_a(String)
  end

  it 'does not collide identities containing the old delimiter with other domains' do
    expect(described_class.milestone_acknowledgment(identity: 'a:b', domain: 'c', old_mode: :observe,
                                                    new_mode: :filter)).to be_a(String)
    expect(described_class.milestone_acknowledgment(identity: 'a', domain: 'b:c', old_mode: :observe,
                                                    new_mode: :filter)).to be_a(String)
  end

  it 'does not consume another humans onboarding or graduation acknowledgment' do
    expect(described_class.onboarding_frame(identity: 'alice')).to be_a(String)
    expect(described_class.onboarding_frame(identity: 'alice')).to be_nil
    expect(described_class.onboarding_frame(identity: 'bob')).to be_a(String)
    expect(described_class.graduation_acknowledgment(identity: 'alice')).to be_a(String)
    expect(described_class.graduation_acknowledgment(identity: 'alice')).to be_nil
    expect(described_class.graduation_acknowledgment(identity: 'bob')).to be_a(String)
  end

  it 'returns uncertainty only for the human whose behavior is still an observed inference' do
    Legion::Gaia::BehavioralSynapse.crystallize(identity: 'alice', domain: 'tone', directive: 'casual',
                                                origin: 'emergent')
    expect(described_class.epistemic_qualifier(identity: 'alice', domain: 'tone')).to be_a(String)
    expect(described_class.epistemic_qualifier(identity: 'bob', domain: 'tone')).to be_nil
  end

  it 'uses explicitly human-scoped imprint state and never the node-global singleton' do
    registry = double('registry')
    alice = double('alice imprint', imprint_state_for: { active: true, observations_count: 2 })
    bob = double('bob imprint', imprint_state_for: { active: false, observations_count: 100 })
    allow(registry).to receive(:runner_instances_for).with(identity: 'alice').and_return(Coldstart_Coldstart: alice)
    allow(registry).to receive(:runner_instances_for).with(identity: 'bob').and_return(Coldstart_Coldstart: bob)
    allow(Legion::Gaia).to receive(:registry).and_return(registry)
    expect(described_class.epistemic_qualifier(identity: 'alice')).to be_a(String)
    expect(described_class.epistemic_qualifier(identity: 'bob')).to be_nil
  end

  it 'does not generate anonymous relationship messages' do
    expect(described_class.onboarding_frame(identity: nil)).to be_nil
    expect(described_class.graduation_acknowledgment(identity: nil)).to be_nil
    expect(described_class.pain_revert_acknowledgment(identity: nil, domain: 'tone')).to be_nil
    expect(described_class.milestone_acknowledgment(identity: nil, domain: 'tone', old_mode: :observe,
                                                    new_mode: :filter)).to be_nil
  end
end
