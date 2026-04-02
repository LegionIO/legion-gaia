# frozen_string_literal: true

RSpec.describe Legion::Gaia::Registry do
  let(:logging_stub) do
    Module.new.tap do |mod|
      mod.define_singleton_method(:configuration_generation) { 0 }
      %i[debug info warn error fatal unknown].each do |level|
        mod.define_singleton_method(level) { |_msg| nil }
      end
      mod.const_set(:TaggedLogger, Class.new do
        def initialize(**); end

        %i[debug info warn error fatal unknown].each do |level|
          define_method(level) { |_msg = nil| nil }
        end
      end)
    end
  end

  before do
    stub_const('Legion::Logging', logging_stub)
  end

  subject(:registry) { described_class.instance.tap(&:reset!) }

  describe '#initialize' do
    it 'starts with empty state' do
      expect(registry.runner_instances).to eq({})
      expect(registry.phase_handlers).to eq({})
      expect(registry.discovery).to eq({})
    end
  end

  describe '#discover' do
    it 'populates discovery hash' do
      registry.discover
      expect(registry.discovery).to be_a(Hash)
      expect(registry.discovery).not_to be_empty
    end

    it 'reports total_count from PHASE_MAP unique entries' do
      registry.discover
      expect(registry.total_count).to be_positive
    end
  end

  describe '#rediscover' do
    it 'clears and rebuilds' do
      registry.discover
      result = registry.rediscover
      expect(result[:rediscovered]).to be true
      expect(result).to have_key(:wired_phases)
      expect(result).to have_key(:phase_list)
    end
  end

  describe '#ensure_wired' do
    it 'triggers discover when empty' do
      expect(registry.phase_handlers).to eq({})
      registry.ensure_wired
      expect(registry.discovery).not_to be_empty
    end

    it 'does not re-discover when already wired' do
      registry.discover
      original_discovery = registry.discovery.object_id
      registry.ensure_wired
      expect(registry.discovery.object_id).to eq(original_discovery)
    end
  end

  describe '#tick_host' do
    it 'returns nil when lex-tick not loaded' do
      registry.discover
      expect(registry.tick_host).to be_nil
    end
  end

  describe '#loaded_count' do
    it 'returns 0 when no extensions loaded' do
      registry.discover
      expect(registry.loaded_count).to eq(0)
    end
  end

  describe '#phase_list' do
    it 'returns empty array initially' do
      expect(registry.phase_list).to eq([])
    end
  end
end
