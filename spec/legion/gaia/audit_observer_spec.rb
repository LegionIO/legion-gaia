# frozen_string_literal: true

require 'spec_helper'

RSpec.describe Legion::Gaia::AuditObserver do
  before { described_class.instance.reset! }

  describe '#process_event' do
    let(:event) do
      {
        request_id: 'req_abc',
        caller: { requested_by: { identity: 'user:matt', type: :user } },
        routing: { provider: :anthropic, model: 'claude-opus-4-6' },
        tokens: { input: 100, output: 50, total: 150 },
        messages: [{ role: :user, content: 'list my files' }],
        tools_used: [{ name: 'list_files' }],
        timestamp: Time.now
      }
    end

    it 'records user routing preference' do
      described_class.instance.process_event(event)
      prefs = described_class.instance.user_preferences('user:matt')
      expect(prefs[:routing]).to include(provider: :anthropic)
    end

    it 'records tool usage patterns' do
      described_class.instance.process_event(event)
      patterns = described_class.instance.tool_patterns
      expect(patterns).to have_key('list_files')
      expect(patterns['list_files'][:count]).to eq(1)
    end

    it 'accumulates across multiple events' do
      3.times { described_class.instance.process_event(event) }
      patterns = described_class.instance.tool_patterns
      expect(patterns['list_files'][:count]).to eq(3)
    end

    it 'exposes learned data for advisory' do
      described_class.instance.process_event(event)
      learned = described_class.instance.learned_data_for('user:matt')
      expect(learned).to have_key(:routing_preference)
      expect(learned).to have_key(:tool_predictions)
    end

    it 'does not raise on malformed event' do
      expect { described_class.instance.process_event({}) }.not_to raise_error
      expect { described_class.instance.process_event(nil) }.not_to raise_error
    end
  end

  describe '#user_preferences' do
    it 'returns empty hash for unknown identity' do
      expect(described_class.instance.user_preferences('unknown')).to eq({})
    end
  end

  describe '#tool_patterns' do
    it 'returns empty hash when no events processed' do
      expect(described_class.instance.tool_patterns).to eq({})
    end
  end

  describe '#reset!' do
    it 'clears all accumulated state' do
      event = {
        caller: { requested_by: { identity: 'user:matt', type: :user } },
        routing: { provider: :anthropic }, tokens: {},
        tools_used: [{ name: 'list_files' }], timestamp: Time.now
      }
      described_class.instance.process_event(event)
      described_class.instance.reset!
      expect(described_class.instance.tool_patterns).to eq({})
      expect(described_class.instance.user_preferences('user:matt')).to eq({})
    end
  end
end
