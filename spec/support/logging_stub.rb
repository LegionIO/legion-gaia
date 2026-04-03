# frozen_string_literal: true

# Shared helper that builds a stub for Legion::Logging suitable for use in specs.
# Use via: stub_const('Legion::Logging', logging_stub)
module LoggingStubHelper
  def logging_stub
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
end

RSpec.configure do |config|
  config.include LoggingStubHelper
end
