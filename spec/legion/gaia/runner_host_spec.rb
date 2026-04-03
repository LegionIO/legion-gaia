# frozen_string_literal: true

RSpec.describe Legion::Gaia::RunnerHost do
  let(:test_module) do
    Module.new do
      def test_method
        { result: :ok }
      end
    end
  end

  subject(:host) { described_class.new(test_module) }

  it 'extends the host with the runner module' do
    expect(host).to respond_to(:test_method)
  end

  it 'calls methods on the runner module' do
    expect(host.test_method).to eq({ result: :ok })
  end

  it 'calls singleton methods defined on the runner module' do
    singleton_module = Module.new do
      def self.retrieve(text:, **)
        { text: text, source: :singleton_module }
      end
    end

    singleton_host = described_class.new(singleton_module)
    expect(singleton_host.retrieve(text: 'ping')).to eq({ text: 'ping', source: :singleton_module })
  end

  it 'calls instance methods on class-based runners' do
    runner_class = Class.new do
      def reflect(topic:, **)
        { topic: topic, source: :class_instance }
      end
    end

    class_host = described_class.new(runner_class)
    expect(class_host.reflect(topic: 'memory')).to eq({ topic: 'memory', source: :class_instance })
  end

  it 'isolates instance state between hosts' do
    stateful_module = Module.new do
      def increment
        @counter ||= 0
        @counter += 1
      end
    end

    host_a = described_class.new(stateful_module)
    host_b = described_class.new(stateful_module)

    3.times { host_a.increment }
    host_b.increment

    expect(host_a.increment).to eq(4)
    expect(host_b.increment).to eq(2)
  end

  it 'has a readable to_s' do
    expect(host.to_s).to include('RunnerHost')
  end

  it 'has a readable inspect' do
    expect(host.inspect).to include('RunnerHost')
  end
end
