# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::DeathProtocol do
  let(:identity_x) { 'partner-x' }
  let(:identity_y) { 'partner-y' }

  before do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
    Legion::Gaia::BondRegistry.register(identity_x, bond: :partner, strength: 0.8)
    Legion::Gaia::BondRegistry.register(identity_y, bond: :partner, strength: 0.7)
    Legion::Gaia::BehavioralSynapse.crystallize(
      identity: identity_x, domain: 'brevity', directive: 'be brief', origin: 'explicit'
    )
    Legion::Gaia::BehavioralSynapse.crystallize(
      identity: identity_y, domain: 'detail', directive: 'be detailed', origin: 'explicit'
    )
  end

  after do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  describe '.terminate_bond' do
    context 'without confirm: true' do
      it 'raises ArgumentError' do
        expect { described_class.terminate_bond(identity: identity_x, confirm: false) }
          .to raise_error(ArgumentError, /confirm: must be true/)
      end

      it 'raises when confirm is nil' do
        expect { described_class.terminate_bond(identity: identity_x, confirm: nil) }
          .to raise_error(ArgumentError, /confirm: must be true/)
      end
    end

    context 'happy path' do
      subject(:result) { described_class.terminate_bond(identity: identity_x, confirm: true) }

      it 'returns terminated: true' do
        expect(result[:terminated]).to be true
      end

      it 'returns the identity string' do
        expect(result[:identity]).to eq(identity_x)
      end

      it 'includes a receipt hash' do
        expect(result[:receipt]).to be_a(Hash)
      end

      it 'includes bond store in receipt' do
        expect(result[:receipt]).to have_key(:bond)
      end

      it 'includes behavioral_synapses in receipt' do
        expect(result[:receipt]).to have_key(:behavioral_synapses)
      end

      it 'includes session in receipt' do
        expect(result[:receipt]).to have_key(:session)
      end

      it 'includes audit in receipt' do
        expect(result[:receipt]).to have_key(:audit)
      end

      it 'includes attribution in receipt' do
        expect(result[:receipt]).to have_key(:attribution)
      end

      it 'erases bond registry entry for X' do
        result
        expect(Legion::Gaia::BondRegistry.bond(identity_x)).to eq(:unknown)
      end

      it 'erases behavioral synapses for X' do
        result
        expect(Legion::Gaia::BehavioralSynapse.all_for(identity: identity_x)).to be_empty
      end

      it 'sets bond state to :terminated' do
        result
        expect(Legion::Gaia::BondRegistry.terminated?(identity_x)).to be true
      end
    end

    context 'Y untouched after X terminated' do
      before { described_class.terminate_bond(identity: identity_x, confirm: true) }

      it 'leaves Y bond intact' do
        expect(Legion::Gaia::BondRegistry.bond(identity_y)).to eq(:partner)
      end

      it 'leaves Y synapses intact' do
        expect(Legion::Gaia::BehavioralSynapse.all_for(identity: identity_y)).not_to be_empty
      end

      it 'does not mark Y as terminated' do
        expect(Legion::Gaia::BondRegistry.terminated?(identity_y)).to be false
      end
    end

    context 'event emission' do
      it 'emits gaia.bond.terminated when Legion::Events is available' do
        events_stub = double('Events')
        stub_const('Legion::Events', events_stub)
        allow(events_stub).to receive(:respond_to?).with(:emit).and_return(true)
        # BondRegistry.erase_partner! also emits gaia.bond.erased — allow it
        allow(events_stub).to receive(:emit).with('gaia.bond.erased', anything)
        expect(events_stub).to receive(:emit).with(
          'gaia.bond.terminated',
          hash_including(identity: identity_x)
        )
        described_class.terminate_bond(identity: identity_x, confirm: true)
      end

      it 'does not raise if Legion::Events is not defined' do
        hide_const('Legion::Events') if defined?(Legion::Events)
        expect { described_class.terminate_bond(identity: identity_x, confirm: true) }.not_to raise_error
      end
    end
  end

  describe 'ingress barrier' do
    context 'when identity is :terminating' do
      before { Legion::Gaia::BondRegistry.set_bond_state(identity_x, :terminating) }

      it 'terminating? returns true' do
        expect(Legion::Gaia::BondRegistry.terminating?(identity_x)).to be true
      end

      it 'terminated? returns false' do
        expect(Legion::Gaia::BondRegistry.terminated?(identity_x)).to be false
      end
    end

    context 'when identity is :terminated' do
      before { described_class.terminate_bond(identity: identity_x, confirm: true) }

      it 'terminated? returns true' do
        expect(Legion::Gaia::BondRegistry.terminated?(identity_x)).to be true
      end

      it 'terminating? returns false after full termination' do
        expect(Legion::Gaia::BondRegistry.terminating?(identity_x)).to be false
      end
    end
  end

  describe 'irreversibility — cannot re-bond after termination' do
    before { described_class.terminate_bond(identity: identity_x, confirm: true) }

    it 'observe_interlocutor no-ops for terminated identity' do
      frame = instance_double(
        Legion::Gaia::InputFrame,
        auth_context: { identity: identity_x },
        channel_id: :cli,
        content_type: :text,
        content: 'hello',
        metadata: { direct_address: false },
        received_at: Time.now.utc
      )
      # If observe_interlocutor returned without registering, bond stays :unknown
      Legion::Gaia.send(:observe_interlocutor, frame, identity_x)
      # Bond should remain :unknown — terminated identity not re-registered
      expect(Legion::Gaia::BondRegistry.bond(identity_x)).to eq(:unknown)
    end
  end
end
