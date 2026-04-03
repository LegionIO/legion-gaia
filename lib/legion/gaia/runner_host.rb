# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    class RunnerHost
      include Legion::Logging::Helper

      attr_accessor :last_tick_result

      def initialize(runner_module)
        @runner_module = runner_module
        extend runner_module if runner_module.is_a?(Module) && !runner_module.is_a?(Class)
        log.debug("RunnerHost initialized runner_module=#{runner_module}")
      end

      def method_missing(method_name, ...)
        return @runner_module.public_send(method_name, ...) if @runner_module.respond_to?(method_name)

        instance = runner_instance
        return instance.public_send(method_name, ...) if instance.respond_to?(method_name)

        super
      end

      def respond_to_missing?(method_name, include_private = false)
        return true if @runner_module.respond_to?(method_name, include_private)
        return true if @runner_module.is_a?(Class) && @runner_module.method_defined?(method_name)

        super
      end

      def to_s
        "RunnerHost(#{@runner_module})"
      end

      def inspect
        "#<#{self.class} module=#{@runner_module}>"
      end

      private

      def runner_instance
        return @runner_instance if defined?(@runner_instance)
        return @runner_instance = nil unless @runner_module.is_a?(Class)

        @runner_instance = @runner_module.new
      rescue StandardError => e
        handle_exception(e, level: :debug, operation: 'gaia.runner_host.runner_instance',
                            runner_module: @runner_module.to_s)
        @runner_instance = nil
      end
    end
  end
end
