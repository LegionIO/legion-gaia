# frozen_string_literal: true

require 'singleton'

module Legion
  module Gaia
    class Registry
      include Singleton

      attr_reader :runner_instances, :phase_handlers, :discovery

      def initialize
        reset!
      end

      def reset!
        @runner_instances = {}
        @phase_handlers = {}
        @discovery = {}
        @discovered = false
      end

      def discover
        @runner_instances = build_runner_instances
        @phase_handlers = PhaseWiring.build_phase_handlers(@runner_instances)
        @discovery = PhaseWiring.discover_available_extensions
        @discovered = true

        log_info "[gaia:registry] discovered: #{loaded_count}/#{total_count} extensions, " \
                 "#{wired_count} phases wired"
      end

      def rediscover
        @runner_instances = {}
        @phase_handlers = {}
        @discovery = {}
        @discovered = false
        discover

        { rediscovered: true, wired_phases: wired_count, phase_list: phase_list }
      end

      def ensure_wired
        discover unless @discovered
      end

      def tick_host
        @runner_instances[:Tick_Orchestrator]
      end

      def loaded_count
        @discovery.count { |_, v| v[:loaded] }
      end

      def total_count
        @discovery.size
      end

      def wired_count
        @phase_handlers.size
      end

      def phase_list
        @phase_handlers.keys
      end

      private

      def build_runner_instances
        instances = {}

        # Always wire tick orchestrator
        tick_class = PhaseWiring.resolve_runner_class(:Tick, :Orchestrator)
        if tick_class
          instances[:Tick_Orchestrator] = RunnerHost.new(tick_class)
          log_debug '[gaia:registry] wired: Tick::Orchestrator'
        end

        # Wire all phase map entries
        PhaseWiring::PHASE_MAP.each_value do |value|
          next if value.nil?

          PhaseWiring.mappings_for(value).each do |mapping|
            key = :"#{mapping[:ext]}_#{mapping[:runner]}"
            next if instances.key?(key)

            runner_class = PhaseWiring.resolve_runner_class(mapping[:ext], mapping[:runner])
            if runner_class
              instances[key] = RunnerHost.new(runner_class)
              log_debug "[gaia:registry] wired: #{mapping[:ext]}::#{mapping[:runner]}"
            else
              log_debug "[gaia:registry] skipped: #{mapping[:ext]}::#{mapping[:runner]} (not loaded)"
            end
          end
        end

        instances
      end

      def log_debug(msg)
        Legion::Logging.debug(msg) if Legion.const_defined?('Logging')
      end

      def log_info(msg)
        Legion::Logging.info(msg) if Legion.const_defined?('Logging')
      end
    end
  end
end
