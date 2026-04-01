# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/proactive_dispatcher'

RSpec.describe 'Dream-to-Proactive Bridge' do
  let(:gaia_module) { Legion::Gaia }

  describe '#process_dream_proactive' do
    let(:dispatcher) { Legion::Gaia::ProactiveDispatcher.new }

    before do
      allow(gaia_module).to receive(:proactive_dispatcher).and_return(dispatcher)
      allow(dispatcher).to receive(:dispatch_with_gate).and_return({ dispatched: true })
    end

    it 'queues proactive intent from dream results' do
      dream_results = {
        partner_reflection: {
          proactive_suggestion: { type: :proactive_outreach, trigger: { reason: :insight, content: 'test' } }
        }
      }
      gaia_module.send(:process_dream_proactive, dream_results)
      expect(dispatcher.pending_buffer.size).to eq(1)
    end

    it 'queues from action_selection proactive_outreach' do
      dream_results = {
        action_selection: {
          proactive_outreach: { type: :proactive_outreach, trigger: { reason: :curiosity, content: 'question' } }
        }
      }
      gaia_module.send(:process_dream_proactive, dream_results)
      expect(dispatcher.pending_buffer.size).to eq(1)
    end

    it 'does nothing with nil dream results' do
      gaia_module.send(:process_dream_proactive, nil)
      expect(dispatcher.pending_buffer).to be_empty
    end

    it 'does nothing without proactive intent' do
      gaia_module.send(:process_dream_proactive, { partner_reflection: { bonds_reflected: 1 } })
      expect(dispatcher.pending_buffer).to be_empty
    end
  end

  describe '#try_dispatch_pending' do
    let(:dispatcher) { Legion::Gaia::ProactiveDispatcher.new }

    before do
      allow(gaia_module).to receive(:proactive_dispatcher).and_return(dispatcher)
      allow(dispatcher).to receive(:dispatch_with_gate).and_return({ dispatched: true })
    end

    it 'dispatches pending intents when gate allows' do
      dispatcher.queue_intent({ type: :proactive_outreach, trigger: { reason: :insight } })
      gaia_module.send(:try_dispatch_pending)
      expect(dispatcher.pending_buffer).to be_empty
    end

    it 'stops on first rate-limited result' do
      allow(dispatcher).to receive(:dispatch_with_gate).and_return({ dispatched: false, reason: :rate_limited })
      dispatcher.queue_intent({ type: :proactive_outreach, trigger: { reason: :insight } })
      gaia_module.send(:try_dispatch_pending)
      # Buffer re-queued since dispatch failed
      expect(dispatcher.pending_buffer.size).to eq(1)
    end
  end
end
