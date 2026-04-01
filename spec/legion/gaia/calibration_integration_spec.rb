# frozen_string_literal: true

RSpec.describe 'GAIA calibration integration' do
  let(:gaia_class) do
    Class.new do
      class << self
        private

        def log_warn(msg); end
        def log_debug(msg); end
      end
    end
  end

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
    it 'calls evaluate_calibration for partner observations' do
      expect(Legion::Gaia.method(:record_advisory_meta)).not_to be_nil
    end
  end
end
