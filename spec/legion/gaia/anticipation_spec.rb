# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Anticipation do
  let(:registry) { double('registry') }
  let(:alice_runner) { double('alice prediction runner') }
  let(:bob_runner) { double('bob prediction runner') }
  let(:prediction) do
    { prediction_id: 'p1', identity: 'alice', confidence: 0.8, status: :pending,
      description: 'deploy the service', context: { conversation_id: 'c1', pre_stage_entries: [{ id: 'relevant' }] } }
  end

  before do
    Legion::Gaia::BondRegistry.reset!
    allow(described_class).to receive(:inference_available?).and_return(true)
    allow(Legion::Gaia).to receive(:registry).and_return(registry)
    allow(registry).to receive(:runner_instances_for).with(identity: 'alice')
                                                     .and_return(Prediction_Prediction: alice_runner)
    allow(registry).to receive(:runner_instances_for).with(identity: 'bob')
                                                     .and_return(Prediction_Prediction: bob_runner)
    allow(alice_runner).to receive(:pending_predictions).and_return(predictions: [prediction])
    allow(bob_runner).to receive(:pending_predictions).and_return(predictions: [])
    allow(alice_runner).to receive(:get_prediction).and_return(found: true, prediction: prediction)
    allow(bob_runner).to receive(:get_prediction).and_return(found: false)
  end

  after { Legion::Gaia::BondRegistry.reset! }

  it 'reads the existing live human runner rather than constructing a new empty store' do
    result = described_class.build(identity: 'alice', context: { conversation_id: 'c1', rag_entry_count: 8 })
    expect(result).to include(prediction_id: 'p1', content: 'deploy the service', pre_staged: [{ id: 'relevant' }])
    expect(described_class.build(identity: 'bob', context: { conversation_id: 'c1' })).to be_nil
  end

  it 'does not expose predictions from another human or conversation' do
    foreign = prediction.merge(prediction_id: 'private', identity: 'bob', confidence: 1.0)
    allow(alice_runner).to receive(:pending_predictions).and_return(predictions: [foreign, prediction])
    expect(described_class.build(identity: 'alice', context: { conversation_id: 'c1' })[:prediction_id]).to eq('p1')
    expect(described_class.build(identity: 'alice', context: { conversation_id: 'c2' })).to be_nil
  end

  it 'never exceeds a quarter of the existing context even for small context sizes' do
    prediction[:context][:pre_stage_entries] = 20.times.map { |index| { id: index } }
    result = described_class.build(identity: 'alice', context: { conversation_id: 'c1', rag_entry_count: 3 })
    expect(result[:pre_staged]).to eq([])
    result = described_class.build(identity: 'alice', context: { conversation_id: 'c1', rag_entry_count: 8 })
    expect(result[:pre_staged]).to eq([{ id: 0 }, { id: 1 }])
  end

  it 'resolves only a still-pending prediction for the matched human and conversation' do
    expect(alice_runner).to receive(:resolve_prediction).with(prediction_id: 'p1', outcome: :correct,
                                                              actual: 'deploy the service now', identity: 'alice')
                                                        .and_return(resolved: true, outcome: :correct)
    described_class.resolve(identity: 'alice', prediction_id: 'p1', actual: 'deploy the service now',
                            conversation_id: 'c1')
    expect(bob_runner).not_to receive(:resolve_prediction)
    expect(described_class.resolve(identity: 'bob', prediction_id: 'p1', actual: 'yes', conversation_id: 'c1'))
      .to include(resolved: false, reason: :not_found)
    expect(described_class.resolve(identity: 'alice', prediction_id: 'p1', actual: 'yes', conversation_id: 'c2'))
      .to include(resolved: false, reason: :not_found)
    prediction[:status] = :resolved
    expect(described_class.resolve(identity: 'alice', prediction_id: 'p1', actual: 'yes', conversation_id: 'c1'))
      .to include(resolved: false, reason: :already_resolved)
  end

  it 'leaves missing prediction attribution ungraded instead of recording an incorrect outcome' do
    allow(alice_runner).to receive(:get_prediction).and_return(found: false)
    expect(alice_runner).not_to receive(:resolve_prediction)
    expect(described_class.resolve(identity: 'alice', prediction_id: 'missing', actual: 'hello'))
      .to include(resolved: false, reason: :not_found)
  end

  it 'defers negative anticipations using this humans live empathy state' do
    prediction[:emotional_context] = { valence: -0.6 }
    empathy = double('live empathy', perspective_take: { model: { emotional_state: :stressed } })
    allow(registry).to receive(:runner_instances_for).with(identity: 'alice').and_return(
      Prediction_Prediction: alice_runner, Empathy_Empathy: empathy
    )
    expect(described_class.build(identity: 'alice', context: { conversation_id: 'c1' })).to be_nil
    allow(empathy).to receive(:perspective_take).and_return(model: { emotional_state: :calm })
    expect(described_class.build(identity: 'alice', context: { conversation_id: 'c1' })[:prediction_id]).to eq('p1')
  end

  it 'fails closed on an unavailable identity entropy check before resolving' do
    fingerprint = double('fingerprint')
    allow(fingerprint).to receive(:check_entropy).and_raise(IOError, 'unavailable')
    allow(registry).to receive(:runner_instances_for).with(identity: 'alice').and_return(
      Prediction_Prediction: alice_runner, Identity_Identity: fingerprint
    )
    expect(alice_runner).not_to receive(:resolve_prediction)
    expect(described_class.resolve(identity: 'alice', prediction_id: 'p1', actual: 'deploy', conversation_id: 'c1'))
      .to include(resolved: false, reason: :high_entropy)
  end

  it 'keeps optional absence and anonymous use unpersonalized' do
    expect(described_class.build(identity: nil, context: {})).to be_nil
    allow(described_class).to receive(:inference_available?).and_return(false)
    expect(described_class.build(identity: 'alice', context: {})).to be_nil
    expect(described_class.resolve(identity: 'alice', prediction_id: 'p1', actual: 'deploy')).to be_nil
  end
end
