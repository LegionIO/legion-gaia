# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::Advisory do
  describe '.advise' do
    it 'returns nil when GAIA is not started' do
      allow(Legion::Gaia).to receive(:started?).and_return(false)
      result = described_class.advise(conversation_id: 'conv_1', messages: [], caller: {})
      expect(result).to be_nil
    end

    it 'returns advisory hash when GAIA is started' do
      allow(Legion::Gaia).to receive(:started?).and_return(true)
      allow(Legion::Gaia).to receive(:last_valences).and_return([0.6, 0.3])
      allow(Legion::Gaia).to receive(:registry).and_return(
        double(tick_host: double(
          last_tick_result: {
            results: {
              prediction_engine: { predictions: [{ tool: 'list_files', confidence: 0.8 }] },
              sensory_processing: { suppressed: [:billing] }
            }
          }
        ))
      )

      result = described_class.advise(
        conversation_id: 'conv_1',
        messages: [{ role: :user, content: 'list my files' }],
        caller: { requested_by: { identity: 'user:matt', type: :user } }
      )

      expect(result).to be_a(Hash)
      expect(result).to have_key(:valence)
      expect(result[:valence]).to eq([0.6, 0.3])
      expect(result).to have_key(:tool_hint)
      expect(result).to have_key(:suppress)
    end

    it 'returns empty hash when tick_host has no results' do
      allow(Legion::Gaia).to receive(:started?).and_return(true)
      allow(Legion::Gaia).to receive(:last_valences).and_return(nil)
      allow(Legion::Gaia).to receive(:registry).and_return(
        double(tick_host: double(last_tick_result: nil))
      )

      result = described_class.advise(
        conversation_id: 'conv_1', messages: [], caller: {}
      )
      expect(result).to be_a(Hash)
      expect(result[:valence]).to be_nil
      expect(result[:tool_hint]).to be_nil
    end

    it 'never raises, returns nil on error' do
      allow(Legion::Gaia).to receive(:started?).and_raise(StandardError, 'boom')
      result = described_class.advise(conversation_id: 'c', messages: [], caller: {})
      expect(result).to be_nil
    end
  end
end
