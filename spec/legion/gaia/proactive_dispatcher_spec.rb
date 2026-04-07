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
      expect(result[:channel_id]).to eq('teams')
    end

    it 'blocks when limit reached' do
      3.times { dispatcher.record_dispatch! }
      result = dispatcher.dispatch_with_gate(intent)
      expect(result[:dispatched]).to be false
      expect(result[:reason]).to eq(:rate_limited)
    end

    it 'does not consume quota when downstream delivery fails' do
      allow(proactive).to receive(:send_notification).and_return(
        { 'teams' => { delivered: false, error: :adapter_failed } }
      )

      result = dispatcher.dispatch_with_gate(intent)

      expect(result[:dispatched]).to be false
      expect(result[:reason]).to eq(:adapter_failed)
      expect(dispatcher.dispatches_today).to eq(0)
    end

    it 'returns no_partner_channel and does not broadcast when channel resolution fails' do
      allow(dispatcher).to receive(:resolve_partner_channel).and_return(nil)
      expect(proactive).not_to receive(:send_notification)

      result = dispatcher.dispatch_with_gate(intent)

      expect(result[:dispatched]).to be false
      expect(result[:reason]).to eq(:no_partner_channel)
      expect(dispatcher.dispatches_today).to eq(0)
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

  describe '#resolve_partner_id (§9.6 channel-identity routing)' do
    context 'when no partner bond is registered' do
      before { Legion::Gaia::BondRegistry.reset! }
      after  { Legion::Gaia::BondRegistry.reset! }

      it 'returns nil' do
        expect(dispatcher.send(:resolve_partner_id)).to be_nil
      end
    end

    context 'when partner bond has no channel_identity' do
      before do
        Legion::Gaia::BondRegistry.reset!
        Legion::Gaia::BondRegistry.register('esity', bond: :partner)
      end
      after { Legion::Gaia::BondRegistry.reset! }

      it 'falls back to the identity string' do
        expect(dispatcher.send(:resolve_partner_id)).to eq('esity')
      end
    end

    context 'when partner bond has a channel_identity (UUID principal + channel-native ID)' do
      let(:uuid) { 'a1b2c3d4-1111-0000-0000-000000000001' }

      before do
        Legion::Gaia::BondRegistry.reset!
        Legion::Gaia::BondRegistry.register(uuid, bond: :partner, channel_identity: 'U_SLACK_123')
      end
      after { Legion::Gaia::BondRegistry.reset! }

      it 'returns the channel-native identity for delivery' do
        expect(dispatcher.send(:resolve_partner_id)).to eq('U_SLACK_123')
      end

      it 'does not return the principal UUID to channel APIs' do
        expect(dispatcher.send(:resolve_partner_id)).not_to eq(uuid)
      end
    end

    context 'when BondRegistry is not defined' do
      before { hide_const('Legion::Gaia::BondRegistry') }

      it 'returns nil' do
        expect(dispatcher.send(:resolve_partner_id)).to be_nil
      end
    end
  end

  describe '#resolve_partner_channel (Fix 6)' do
    context 'when BondRegistry is not defined' do
      before { hide_const('Legion::Gaia::BondRegistry') }

      it 'returns nil' do
        expect(dispatcher.send(:resolve_partner_channel)).to be_nil
      end
    end

    context 'when BondRegistry has no partner bond' do
      before do
        allow(Legion::Gaia::BondRegistry).to receive(:all_bonds).and_return([])
      end

      it 'returns nil' do
        expect(dispatcher.send(:resolve_partner_channel)).to be_nil
      end
    end

    context 'when partner bond has a preferred_channel' do
      before do
        allow(Legion::Gaia::BondRegistry).to receive(:all_bonds).and_return([
                                                                              { bond: :partner, role: :partner,
                                                                                identity: 'esity',
                                                                                preferred_channel: :teams }
                                                                            ])
      end

      it 'returns the preferred_channel' do
        expect(dispatcher.send(:resolve_partner_channel)).to eq(:teams)
      end
    end

    context 'when partner bond has a last_channel but no preferred_channel' do
      before do
        allow(Legion::Gaia::BondRegistry).to receive(:all_bonds).and_return([
                                                                              { bond: :partner, role: :partner,
                                                                                identity: 'esity',
                                                                                last_channel: :slack }
                                                                            ])
      end

      it 'falls back to last_channel' do
        expect(dispatcher.send(:resolve_partner_channel)).to eq(:slack)
      end
    end

    context 'when non-partner bond exists but no partner bond' do
      before do
        allow(Legion::Gaia::BondRegistry).to receive(:all_bonds).and_return([
                                                                              { bond: :colleague, role: :colleague,
                                                                                identity: 'someone',
                                                                                preferred_channel: :cli }
                                                                            ])
      end

      it 'returns nil' do
        expect(dispatcher.send(:resolve_partner_channel)).to be_nil
      end
    end
  end
end
