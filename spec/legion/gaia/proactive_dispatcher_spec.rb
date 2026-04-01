# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/proactive_dispatcher'

RSpec.describe Legion::Gaia::ProactiveDispatcher do
  subject(:dispatcher) { described_class.new }

  describe 'limits' do
    it 'has default max_per_day of 3' do
      expect(dispatcher.max_per_day).to eq(3)
    end

    it 'has default min_interval of 7200 seconds' do
      expect(dispatcher.min_interval).to eq(7200)
    end

    it 'has default ignore_cooldown of 86400 seconds' do
      expect(dispatcher.ignore_cooldown).to eq(86_400)
    end
  end

  describe '#can_dispatch?' do
    it 'allows first dispatch' do
      expect(dispatcher.can_dispatch?).to be true
    end

    it 'blocks after max_per_day reached' do
      3.times { dispatcher.record_dispatch! }
      expect(dispatcher.can_dispatch?).to be false
    end

    it 'blocks within min_interval' do
      dispatcher.record_dispatch!
      expect(dispatcher.can_dispatch?).to be false
    end

    it 'allows after min_interval passes' do
      dispatcher.record_dispatch!
      dispatcher.instance_variable_get(:@dispatch_log).first[:at] = Time.now.utc - 7201
      expect(dispatcher.can_dispatch?).to be true
    end

    it 'blocks during ignore cooldown' do
      dispatcher.record_ignored!
      expect(dispatcher.can_dispatch?).to be false
    end

    it 'allows after ignore cooldown passes' do
      dispatcher.record_ignored!
      dispatcher.instance_variable_set(:@last_ignored_at, Time.now.utc - 86_401)
      expect(dispatcher.can_dispatch?).to be true
    end
  end

  describe '#record_dispatch!' do
    it 'increments dispatch count' do
      dispatcher.record_dispatch!
      expect(dispatcher.dispatches_today).to eq(1)
    end

    it 'prunes entries older than 24 hours' do
      dispatcher.instance_variable_set(:@dispatch_log,
                                       [{ at: Time.now.utc - 90_000 }, { at: Time.now.utc - 100 }])
      dispatcher.record_dispatch!
      expect(dispatcher.dispatches_today).to eq(2)
    end
  end

  describe '#record_ignored!' do
    it 'sets cooldown timestamp' do
      dispatcher.record_ignored!
      expect(dispatcher.instance_variable_get(:@last_ignored_at)).to be_a(Time)
    end
  end

  describe '#dispatch_with_gate' do
    let(:intent) { { type: :proactive_outreach, trigger: { reason: :insight, content: 'test' } } }
    let(:proactive) { double('proactive') }

    before do
      allow(dispatcher).to receive(:proactive_module).and_return(proactive)
      allow(dispatcher).to receive(:generate_content).and_return('Hello!')
      allow(dispatcher).to receive(:resolve_partner_channel).and_return('teams')
      allow(dispatcher).to receive(:resolve_partner_id).and_return('partner-1')
    end

    it 'delivers when allowed' do
      allow(proactive).to receive(:send_notification).and_return({ delivered: true })
      result = dispatcher.dispatch_with_gate(intent)
      expect(result[:dispatched]).to be true
    end

    it 'blocks when limit reached' do
      3.times { dispatcher.record_dispatch! }
      result = dispatcher.dispatch_with_gate(intent)
      expect(result[:dispatched]).to be false
      expect(result[:reason]).to eq(:rate_limited)
    end
  end

  describe '#pending_buffer' do
    it 'starts empty' do
      expect(dispatcher.pending_buffer).to be_empty
    end

    it 'caps at 5 entries' do
      6.times { |i| dispatcher.queue_intent({ id: i }) }
      expect(dispatcher.pending_buffer.size).to eq(5)
    end
  end
end
