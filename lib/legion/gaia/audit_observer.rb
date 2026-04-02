# frozen_string_literal: true

require 'singleton'
require 'legion/logging/helper'

module Legion
  module Gaia
    class AuditObserver
      include Singleton
      include Legion::Logging::Helper

      def initialize
        @user_prefs = {}
        @tool_patterns = {}
        @quality_log  = []
        @mutex        = Mutex.new
      end

      def process_event(event)
        return unless event.is_a?(Hash)

        @mutex.synchronize do
          record_routing_preference(event)
          record_tool_patterns(event)
          record_quality(event)
        end
        identity = event.dig(:caller, :requested_by, :identity)
        log.debug(
          'AuditObserver processed event ' \
          "identity=#{identity || 'unknown'} tools=#{Array(event[:tools_used]).size}"
        )
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.audit_observer.process_event')
      end

      def user_preferences(identity)
        @mutex.synchronize { @user_prefs[identity]&.dup || {} }
      end

      def tool_patterns
        @mutex.synchronize { @tool_patterns.dup }
      end

      def learned_data_for(identity)
        @mutex.synchronize do
          prefs = @user_prefs[identity] || {}
          {
            routing_preference: prefs[:routing],
            tool_predictions: top_tools_for_patterns,
            quality_signals: recent_quality
          }
        end
      end

      def reset!
        @mutex.synchronize do
          @user_prefs.clear
          @tool_patterns.clear
          @quality_log.clear
        end
      end

      private

      def record_routing_preference(event)
        identity = event.dig(:caller, :requested_by, :identity)
        return unless identity

        provider = event.dig(:routing, :provider)
        return unless provider

        @user_prefs[identity] ||= { routing: {}, count: 0 }
        @user_prefs[identity][:routing] = {
          provider: provider,
          model: event.dig(:routing, :model),
          last_used: event[:timestamp]
        }
        @user_prefs[identity][:count] += 1
      end

      def record_tool_patterns(event)
        tools = event[:tools_used] || []
        tools.each do |tool|
          name = tool[:name] || tool['name']
          next unless name

          @tool_patterns[name] ||= { count: 0, last_used: nil }
          @tool_patterns[name][:count] += 1
          @tool_patterns[name][:last_used] = event[:timestamp]
        end
      end

      def record_quality(event)
        @quality_log << {
          provider: event.dig(:routing, :provider),
          tokens: event[:tokens],
          timestamp: event[:timestamp]
        }
        @quality_log.shift if @quality_log.length > 100
      end

      def top_tools_for_patterns
        @tool_patterns.sort_by { |_, v| -v[:count] }.first(10).to_h
      end

      def recent_quality
        @quality_log.last(10)
      end
    end
  end
end
