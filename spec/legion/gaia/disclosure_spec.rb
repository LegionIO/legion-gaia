# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Disclosure do
  let(:identity) { 'partner-alice' }

  before do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  after do
    Legion::Gaia::BondRegistry.reset!
    Legion::Gaia::BehavioralSynapse.reset!
  end

  describe '.report' do
    subject(:report) { described_class.report(identity: identity) }

    it 'returns a Hash' do
      expect(report).to be_a(Hash)
    end

    it 'includes the identity' do
      expect(report[:identity]).to eq(identity)
    end

    it 'includes data_locality statement' do
      expect(report[:data_locality]).to include('stored locally')
    end

    it 'includes termination_available: true' do
      expect(report[:termination_available]).to be true
    end

    context 'when no bond is registered' do
      it 'returns nil for bond_state' do
        expect(report[:bond_state]).to be_nil
      end
    end

    context 'when a partner bond is registered' do
      before { Legion::Gaia::BondRegistry.register(identity, bond: :partner, strength: 0.8) }

      it 'includes bond_state' do
        expect(report[:bond_state]).to be_a(Hash)
      end

      it 'reflects bond type' do
        expect(report[:bond_state][:bond]).to eq(:partner)
      end

      it 'reflects bond strength' do
        expect(report[:bond_state][:strength]).to be_a(Numeric)
      end
    end

    context 'with behavioral synapses' do
      before do
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity, domain: 'brevity', directive: 'keep it short', origin: 'explicit'
        )
        Legion::Gaia::BehavioralSynapse.crystallize(
          identity: identity, domain: 'tone', directive: 'stay casual', origin: 'emergent'
        )
      end

      it 'includes behavioral_synapses array' do
        expect(report[:behavioral_synapses]).to be_an(Array)
      end

      it 'includes synapse count' do
        expect(report[:behavioral_synapses].size).to eq(2)
      end

      it 'each synapse entry includes required fields' do
        entry = report[:behavioral_synapses].first
        expect(entry).to include(:id, :domain, :directive, :confidence, :autonomy_mode, :status)
      end

      it 'reports autonomy_mode as a recognized tier symbol' do
        valid = %i[observe filter transform autonomous]
        modes = report[:behavioral_synapses].map { |s| s[:autonomy_mode] }
        modes.each { |m| expect(valid).to include(m) }
      end
    end

    context 'when no synapses exist' do
      it 'returns nil for behavioral_synapses' do
        expect(report[:behavioral_synapses]).to be_nil
      end
    end

    context 'soft-guards on optional modules' do
      it 'returns nil for preferences when module is not loaded' do
        expect(report[:preferences]).to be_nil
      end

      it 'returns nil for calibration_weights when module is not loaded' do
        expect(report[:calibration_weights]).to be_nil
      end

      it 'returns nil for imprint_state when Coldstart is not loaded' do
        expect(report[:imprint_state]).to be_nil
      end

      it 'returns nil for prediction_accuracy when module is not loaded' do
        expect(report[:prediction_accuracy]).to be_nil
      end

      it 'does not raise when all optional modules are absent' do
        expect { report }.not_to raise_error
      end
    end

    context 'bond lifecycle state' do
      before do
        Legion::Gaia::BondRegistry.register(identity, bond: :partner, strength: 0.8)
        Legion::Gaia::BondRegistry.set_bond_state(identity, :terminating)
      end

      it 'reflects lifecycle state in bond_state' do
        expect(report[:bond_state][:lifecycle_state]).to eq(:terminating)
      end
    end
  end
end
