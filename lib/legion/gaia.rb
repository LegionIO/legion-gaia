# frozen_string_literal: true

require 'legion/gaia/version'
require 'legion/gaia/settings'
require 'legion/gaia/runner_host'
require 'legion/gaia/sensory_buffer'
require 'legion/gaia/phase_wiring'
require 'legion/gaia/registry'

module Legion
  module Gaia
    class << self
      attr_reader :sensory_buffer, :registry

      def boot
        log_info 'Legion::Gaia booting'

        @sensory_buffer = SensoryBuffer.new
        @registry = Registry.new
        @registry.discover

        @started = true
        settings_hash = settings
        settings_hash[:connected] = true if settings_hash

        log_info "Legion::Gaia booted: #{@registry.wired_count} phases wired, " \
                 "#{@registry.loaded_count}/#{@registry.total_count} extensions loaded"
      end

      def shutdown
        log_info 'Legion::Gaia shutting down'

        @started = false
        settings_hash = settings
        settings_hash[:connected] = false if settings_hash

        @sensory_buffer = nil
        @registry = nil

        log_info 'Legion::Gaia shut down'
      end

      def started?
        @started == true
      end

      def settings
        if Legion.const_defined?('Settings')
          Legion::Settings[:gaia]
        else
          Legion::Gaia::Settings.default
        end
      end

      def heartbeat(**)
        return { error: :not_started } unless started?

        signals = @sensory_buffer.drain
        @registry.ensure_wired

        tick_host = @registry.tick_host
        unless tick_host
          log_warn '[gaia] lex-tick not available, will retry next heartbeat'
          return { error: :no_tick_extension }
        end

        phase_handlers = @registry.phase_handlers

        log_debug "[gaia] heartbeat: signals=#{signals.size} wired_phases=#{phase_handlers.size}"

        result = tick_host.execute_tick(signals: signals, phase_handlers: phase_handlers)

        if result.is_a?(Hash) && result[:results]
          valence_result = result[:results][:emotional_evaluation]
          @last_valences = [valence_result[:valence]] if valence_result.is_a?(Hash) && valence_result[:valence]
        end

        result
      end

      def status
        return { started: false } unless started?

        registry_status.merge(started: true, buffer_depth: @sensory_buffer&.size || 0)
      end

      private

      def registry_status
        return {} unless @registry

        {
          extensions_loaded: @registry.loaded_count,
          extensions_total: @registry.total_count,
          wired_phases: @registry.wired_count,
          phase_list: @registry.phase_list
        }
      end

      def log_debug(msg)
        Legion::Logging.debug(msg) if Legion.const_defined?('Logging')
      end

      def log_info(msg)
        Legion::Logging.info(msg) if Legion.const_defined?('Logging')
      end

      def log_warn(msg)
        Legion::Logging.warn(msg) if Legion.const_defined?('Logging')
      end
    end
  end
end
