# frozen_string_literal: true

RSpec.describe 'GAIA calibration integration' do
  describe '.record_advisory_meta' do
    before do
      stub_const('Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration', Module.new)
      allow_any_instance_of(Object).to receive(:extend)
      allow_any_instance_of(Object).to receive(:record_advisory_meta).and_return({ success: true })
    end

    it 'is a public class method on Legion::Gaia' do
      expect(Legion::Gaia).to respond_to(:record_advisory_meta)
    end
  end

  describe 'observe_interlocutor calibration path' do
    let(:calibration_module) do
      Module.new do
        def calibration_store
          @calibration_store ||= Object.new
        end

        def update_calibration(**)
          { success: true }
        end
      end
    end

    before do
      stub_const(
        'Legion::Extensions::Agentic::Social::Calibration::Runners::Calibration',
        calibration_module
      )
      allow(Legion::Gaia).to receive(:started?).and_return(true)
      allow(Legion::Gaia).to receive(:log_warn)
      allow(Legion::Gaia).to receive(:log_debug)
      allow(Legion::Gaia).to receive(:record_interaction_trace)
      allow(Legion::Gaia::BondRegistry).to receive(:role).and_return(:partner)
      allow(Legion::Gaia::TrackerPersistence).to receive(:register_tracker)
      Legion::Gaia.instance_variable_set(:@partner_observations, [])
      Legion::Gaia.instance_variable_set(:@calibration_runner, nil)
    end

    after do
      Legion::Gaia.instance_variable_set(:@calibration_runner, nil)
      Legion::Gaia.instance_variable_set(:@partner_observations, nil)
    end

    it 'calls evaluate_calibration for partner observations' do
      input_frame = instance_double(
        'Legion::Gaia::InputFrame',
        channel_id: 'test',
        content_type: :text,
        content: 'hello',
        metadata: { direct_address: true },
        received_at: Time.now.utc,
        auth_context: {}
      )

      Legion::Gaia.send(:observe_interlocutor, input_frame, 'partner-123')

      runner = Legion::Gaia.instance_variable_get(:@calibration_runner)
      expect(runner).not_to be_nil
    end
  end
end
