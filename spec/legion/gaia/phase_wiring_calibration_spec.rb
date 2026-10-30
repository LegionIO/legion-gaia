# frozen_string_literal: true

RSpec.describe Legion::Gaia::PhaseWiring do
  it 'does not fall back to unscoped attachment or preference extraction for a human tick' do
    attachment = Object.new
    def attachment.reflect_on_bonds(**)
      raise 'global partner state must not be read'
    end
    calibration = Object.new
    def calibration.sync_partner_knowledge(**)
      raise 'global interaction traces must not be read'
    end
    handlers = described_class.build_phase_handlers(
      { Social_Attachment: attachment, Social_Calibration: calibration }, identity: 'alice'
    )
    result = handlers[:partner_reflection].call(state: {}, signals: [], prior_results: {}, identity: 'alice')

    expect(result).to include(status: :unavailable, meaningful: false)
    expect(result[:handlers].map do |member|
      member[:reason]
    end).to eq(%i[identity_scope_unsupported identity_scope_unsupported])
  end

  it 'does not borrow another human observation when preparing social inputs' do
    observations = [{ identity: 'alice', content_length: 10 }, { identity: 'bob', content_length: 100 }]
    args = described_class::PHASE_ARGS[:social_cognition].call(identity: 'alice', partner_observations: observations,
                                                               signals: [], prior_results: {})
    expect(args[:human_observations]).to eq([observations.first])
  end
end
