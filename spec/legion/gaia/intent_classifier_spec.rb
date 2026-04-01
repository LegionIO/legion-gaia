# frozen_string_literal: true

require 'spec_helper'
require 'legion/gaia/intent_classifier'

RSpec.describe Legion::Gaia::IntentClassifier do
  describe '.classify' do
    it 'detects greeting' do
      expect(described_class.classify('hello gaia')).to eq(:greeting)
    end

    it 'detects question' do
      expect(described_class.classify('what is the status?')).to eq(:question)
    end

    it 'detects directive' do
      expect(described_class.classify('run the deployment now')).to eq(:directive)
    end

    it 'detects seeking_advice' do
      expect(described_class.classify('what do you think about this approach?')).to eq(:seeking_advice)
    end

    it 'detects urgent' do
      expect(described_class.classify('the server is down, critical issue')).to eq(:urgent)
    end

    it 'defaults to casual for plain text' do
      expect(described_class.classify('ok')).to eq(:casual)
    end

    it 'handles nil gracefully' do
      expect(described_class.classify(nil)).to eq(:casual)
    end

    it 'handles empty string' do
      expect(described_class.classify('')).to eq(:casual)
    end
  end

  describe '.direct_engage?' do
    it 'returns true when gaia is mentioned' do
      expect(described_class.direct_engage?('hey gaia, help me')).to be true
    end

    it 'returns false without mention' do
      expect(described_class.direct_engage?('help me')).to be false
    end
  end

  describe '.classify_with_engagement' do
    it 'returns intent and direct_engage flag' do
      result = described_class.classify_with_engagement('gaia what do you think?')
      expect(result[:intent]).to eq(:seeking_advice)
      expect(result[:direct_engage]).to be true
    end

    it 'returns casual without engagement for short messages' do
      result = described_class.classify_with_engagement('ok')
      expect(result[:intent]).to eq(:casual)
      expect(result[:direct_engage]).to be false
    end
  end

  describe 'INTENT_TYPES' do
    it 'lists all 7 intent types' do
      expect(described_class::INTENT_TYPES.size).to eq(7)
    end
  end
end
