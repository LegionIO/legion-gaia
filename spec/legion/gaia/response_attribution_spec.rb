# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::ResponseAttribution do
  let(:store) do
    Class.new do
      attr_accessor :fail_writes
      attr_reader :rows

      def initialize
        @rows = {}
      end

      def upsert(**entry)
        return { success: false } if fail_writes

        @rows[entry[:tags].sort] = entry.merge(id: @rows.size + 1)
        { success: true }
      end

      def query_by_tags(tags:, limit:)
        matches = @rows.values.select { |row| (tags - row[:tags]).empty? }
        { success: true, results: limit ? matches.first(limit) : matches }
      end
    end.new
  end

  before do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  after do
    described_class.reset!
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  def propose(advisory_id: 'a1', identity: 'alice', conversation_id: 'c1', exchange_id: 'e1')
    described_class.register_advisory(
      advisory_id: advisory_id, identity: identity, conversation_id: conversation_id, exchange_id: exchange_id,
      selected: { behavioral_synapse_ids: ["#{identity}-brief", "#{identity}-tone"], trace_ids: ['t1'],
                  adjustment_ids: ["#{advisory_id}:system_prompt"],
                  sources: [{ source_id: "#{identity}-brief", type: :synapse, domain: 'brevity' }] }
    )
  end

  def deliver(advisory_id: 'a1', identity: 'alice', **applied)
    delivery = { behavioral_synapse_ids: ["#{identity}-brief"], delivery_status: :returned }.merge(applied)
    described_class.record_applied(advisory_id: advisory_id, identity: identity, store: store, applied: delivery)
  end

  def feedback(identity: 'alice', **observation)
    described_class.claim_feedback(identity: identity, store: store,
                                   observation: { feedback_id: 'f1', advisory_id: 'a1' }.merge(observation))
  end

  it 'does not grade a proposal, missing applied IDs, or IDs not selected for this human' do
    propose
    expect(feedback).to include(claimed: false, reason: :unmatched)
    expect(deliver(behavioral_synapse_ids: [])).to include(recorded: false, reason: :missing_applied_ids)
    expect(deliver(behavioral_synapse_ids: ['bob-brief'])).to include(recorded: false, reason: :unselected_ids)
    expect(deliver(identity: 'bob')).to include(recorded: false, reason: :unknown_advisory)
  end

  it 'retains only explicitly applied IDs instead of expanding to every selected source' do
    propose
    recorded = deliver
    expect(recorded).to include(recorded: true, durable: true)
    expect(recorded[:receipt]).to include(behavioral_synapse_ids: ['alice-brief'], trace_ids: [], domain: 'brevity')
    expect(feedback[:receipt][:behavioral_synapse_ids]).to eq(['alice-brief'])
  end

  it 'refuses generated, interrupted, or unspecified delivery outcomes' do
    propose
    %i[generated interrupted].each do |outcome|
      expect(deliver(delivery_status: outcome)).to include(recorded: false, reason: :not_delivered)
    end
    expect(deliver(delivery_status: nil)).to include(recorded: false, reason: :not_delivered)
    expect(described_class.status_for(identity: 'alice')[:pending]).to eq(0)
  end

  it 'rejects an applied receipt that changes the proposal conversation' do
    propose
    expect(deliver(conversation_id: 'someone-elses-conversation')).to include(recorded: false,
                                                                              reason: :correlation_mismatch)
  end

  it 'matches A response, B response, A correction without touching B' do
    propose
    deliver
    propose(advisory_id: 'b1', identity: 'bob', conversation_id: 'b-conversation')
    deliver(advisory_id: 'b1', identity: 'bob')
    expect(feedback[:receipt]).to include(identity: 'alice', advisory_id: 'a1')
    expect(described_class.status_for(identity: 'bob')).to include(pending: 1, uncertain: 0)
    expect(feedback(identity: 'bob')).to include(claimed: false, reason: :unmatched)
  end

  it 'does not guess the latest receipt across or within a conversation' do
    propose
    deliver
    propose(advisory_id: 'a2', exchange_id: 'e2')
    deliver(advisory_id: 'a2')
    expect(feedback(advisory_id: nil)).to include(claimed: false, reason: :missing_correlation)
    expect(feedback(advisory_id: nil, conversation_id: 'c1')).to include(claimed: false, reason: :ambiguous)
    expect(feedback(advisory_id: nil, in_reply_to: 'e1', conversation_id: 'c1')[:receipt][:advisory_id]).to eq('a1')
  end

  it 'keeps one humans conversations separate even with delayed feedback' do
    propose
    deliver
    propose(advisory_id: 'a2', conversation_id: 'c2', exchange_id: 'e2')
    deliver(advisory_id: 'a2')
    expect(feedback(advisory_id: 'a1', conversation_id: 'c2')).to include(claimed: false, reason: :unmatched)
    expect(feedback(advisory_id: nil, conversation_id: 'c1')[:receipt][:advisory_id]).to eq('a1')
  end

  it 'requires a unique feedback identifier and rejects contradictory human identity' do
    propose
    deliver
    expect(feedback(feedback_id: nil)).to include(claimed: false, reason: :missing_feedback_id)
    result = described_class.claim_feedback(identity: 'alice', store: store,
                                            observation: { identity: 'bob', feedback_id: 'f1', advisory_id: 'a1' })
    expect(result).to include(claimed: false, reason: :identity_mismatch)
  end

  it 'restores pending receipts and completion tombstones through the registered tracker lifecycle' do
    propose
    deliver
    described_class.reset!
    expect(described_class.from_apollo(store: store)).to be true
    expect(feedback).to include(claimed: true)
    expect(described_class.complete_feedback(identity: 'alice', advisory_id: 'a1', feedback_id: 'f1', store: store))
      .to include(completed: true, durable: true)
    described_class.reset!
    described_class.from_apollo(store: store)
    expect(feedback).to include(claimed: false, reason: :duplicate_feedback)
    expect(feedback(feedback_id: 'f2')).to include(claimed: false, reason: :completed)
    expect(deliver).to include(recorded: false, reason: :duplicate_receipt)
  end

  it 'leaves interrupted durable claims uncertain instead of grading again after restart' do
    propose
    deliver
    expect(feedback).to include(claimed: true)
    described_class.reset!
    described_class.from_apollo(store: store)
    expect(feedback(feedback_id: 'retry')).to include(claimed: false, reason: :uncertain)
    expect(described_class.status_for(identity: 'alice')).to include(uncertain: 1, completed: 0)
  end

  it 'does not authorize learning before a failed claim write is acknowledged' do
    propose
    deliver
    store.fail_writes = true
    expect(feedback).to include(claimed: false, reason: :persistence_unavailable, uncertain: true)
    expect(described_class).to be_dirty
    store.fail_writes = false
    expect(feedback(feedback_id: 'retry')).to include(claimed: false, reason: :uncertain)
  end

  it 'reports persistence failure instead of a successful final receipt' do
    propose
    store.fail_writes = true
    expect(deliver).to include(recorded: false, durable: false, reason: :persistence_unavailable)
    expect(described_class).to be_dirty
  end

  it 'does not permit a duplicate feedback ID to grade a different response' do
    propose
    deliver
    expect(feedback).to include(claimed: true)
    propose(advisory_id: 'a2', exchange_id: 'e2')
    deliver(advisory_id: 'a2')
    expect(feedback(advisory_id: 'a2')).to include(claimed: false, reason: :duplicate_feedback)
  end

  it 'retains completed correlation when rejecting ambiguous delayed conversation-only feedback' do
    propose
    deliver
    feedback
    described_class.complete_feedback(identity: 'alice', advisory_id: 'a1', feedback_id: 'f1', store: store)
    propose(advisory_id: 'a2', exchange_id: 'e2')
    deliver(advisory_id: 'a2')
    expect(feedback(advisory_id: nil, conversation_id: 'c1',
                    feedback_id: 'f2')).to include(claimed: false, reason: :ambiguous)
  end

  it 'persists erasure without removing another humans pending receipt' do
    propose
    deliver
    propose(advisory_id: 'b1', identity: 'bob')
    deliver(advisory_id: 'b1', identity: 'bob')
    expect(described_class.erase_partner!(identity: 'alice', store: store)).to include(erased: true, durable: true)
    described_class.reset!
    described_class.from_apollo(store: store)
    expect(propose).to include(registered: false, reason: :identity_erased)
    expect(feedback(identity: 'bob', advisory_id: 'b1')[:receipt][:identity]).to eq('bob')
  end

  it 'keeps an explicit correction effective after completion and restart without a memory cache' do
    old = Legion::Gaia::BehavioralSynapse.crystallize(identity: 'alice', domain: 'format', origin: 'explicit',
                                                      directive: { format: 'table' })
    described_class.register_advisory(advisory_id: 'a1', identity: 'alice', conversation_id: 'c1', exchange_id: 'e1',
                                      selected: { behavioral_synapse_ids: [old[:id]],
                                                  sources: [{ source_id: old[:id], domain: 'format' }] })
    deliver(behavioral_synapse_ids: [old[:id]])
    expect(feedback(explicit_feedback: :negative, corrected_constraint: { format: 'prose' },
                    domain: 'format')).to include(claimed: true)
    described_class.complete_feedback(identity: 'alice', advisory_id: 'a1', feedback_id: 'f1', store: store)
    described_class.reset!
    described_class.from_apollo(store: store)
    allow(Legion::Gaia).to receive(:registry).and_return(nil)
    model = Legion::Gaia::PartnerModel.build(identity: 'alice', conversation_id: 'c1')
    expect(model).to contain_exactly(hash_including(content: { format: 'prose' }, source: :correction))
    expect(Legion::Gaia::Gut.check(identity: 'alice',
                                   draft_stats: { conversation_id: 'c1',
                                                  format: 'table' })[:conflict]).to be true
    expect(Legion::Gaia::Gut.check(identity: 'alice',
                                   draft_stats: { conversation_id: 'c1',
                                                  format: 'prose' })).to eq(conflict: false)
    expect(described_class.corrections_for(identity: 'bob', conversation_id: 'c1')).to eq([])
    expect(described_class.corrections_for(identity: 'alice', conversation_id: 'c2')).to eq([])
  end

  it 'retains a generic rejection as a veto, never a fabricated replacement preference' do
    propose
    deliver
    feedback(explicit_feedback: :negative, content: 'That was not what I wanted')
    described_class.complete_feedback(identity: 'alice', advisory_id: 'a1', feedback_id: 'f1', store: store)
    described_class.reset!
    described_class.from_apollo(store: store)
    correction = described_class.corrections_for(identity: 'alice', conversation_id: 'c1').first
    expect(correction[:content_payload]).to include(source: 'explicit', corrected_constraint: nil,
                                                    applied_synapse_ids: ['alice-brief'])
    rejected = { id: 'alice-brief', identity: 'alice', domain: 'brevity', directive: 'old preference', confidence: 0.9,
                 status: 'active', origin: 'explicit' }
    expect(Legion::Gaia::PartnerModel.build(identity: 'alice', conversation_id: 'c1', synapses: [rejected],
                                            preferences: [])).to eq([])
  end

  it 'does not expose failed durable feedback claims as response-changing corrections' do
    propose
    deliver
    store.fail_writes = true
    expect(feedback(explicit_feedback: :negative, corrected_constraint: 'be brief')).to include(claimed: false)
    expect(described_class.corrections_for(identity: 'alice', conversation_id: 'c1')).to eq([])
  end

  it 'refuses new attribution after failed hydration instead of overwriting unknown tombstones' do
    allow(store).to receive(:query_by_tags).and_return(success: false, results: [])
    expect(described_class.from_apollo(store: store)).to be false
    expect(propose).to include(registered: false, reason: :hydration_failed)
    expect { described_class.to_apollo_entries }.to raise_error(IOError, 'attribution hydration unavailable')
  end

  it 'does not merge erased identities that differ only by case during persistence' do
    propose(identity: 'Alice')
    deliver(identity: 'Alice')
    propose(identity: 'alice')
    deliver(identity: 'alice')
    described_class.erase_partner!(identity: 'Alice', store: store)
    described_class.reset!
    described_class.from_apollo(store: store)
    expect(propose(identity: 'Alice')).to include(registered: false, reason: :identity_erased)
    expect(feedback(identity: 'alice')[:receipt][:identity]).to eq('alice')
  end
end
