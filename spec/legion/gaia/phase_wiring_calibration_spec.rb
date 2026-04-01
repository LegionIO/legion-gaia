# frozen_string_literal: true

RSpec.describe Legion::Gaia::PhaseWiring do
  describe 'PHASE_MAP[:partner_reflection]' do
    it 'is a multi-handler array' do
      entry = described_class::PHASE_MAP[:partner_reflection]
      expect(entry).to be_an(Array)
      expect(entry.size).to eq(2)
    end

    it 'includes reflect_on_bonds handler' do
      entry = described_class::PHASE_MAP[:partner_reflection]
      bond_handler = entry.find { |h| h[:fn] == :reflect_on_bonds }
      expect(bond_handler).not_to be_nil
      expect(bond_handler[:ext]).to eq(:Social)
      expect(bond_handler[:runner]).to eq(:Attachment)
    end

    it 'includes sync_partner_knowledge handler' do
      entry = described_class::PHASE_MAP[:partner_reflection]
      sync_handler = entry.find { |h| h[:fn] == :sync_partner_knowledge }
      expect(sync_handler).not_to be_nil
      expect(sync_handler[:ext]).to eq(:Social)
      expect(sync_handler[:runner]).to eq(:Calibration)
    end
  end

  describe 'PHASE_ARGS[:partner_reflection]' do
    it 'passes tick_results and bond_summary' do
      args_lambda = described_class::PHASE_ARGS[:partner_reflection]
      ctx = { prior_results: { dream_reflection: { insight: 'test' } } }
      args = args_lambda.call(ctx)
      expect(args).to have_key(:tick_results)
      expect(args).to have_key(:bond_summary)
    end
  end
end
