# frozen_string_literal: true

require 'singleton'
require 'legion/logging/helper'
require 'legion/gaia/bond_registry'
require 'legion/gaia/tracker_persistence'

module Legion
  module Gaia
    class AuditObserver
      include Singleton
      include Legion::Logging::Helper

      def initialize
        @user_prefs          = {}
        @tool_patterns       = {}
        @identity_tool_patterns = {}
        @mutex = Mutex.new
      end

      def process_event(event)
        return unless event.is_a?(Hash)

        Legion::Gaia::TrackerPersistence::WRITE_LOCK.synchronize do
          identity = extract_caller_identity(event)
          if identity && Legion::Gaia::BondRegistry.blocked?(identity: identity)
            return { observed: false,
                     reason: :identity_blocked }
          end

          @mutex.synchronize do
            record_routing_preference(event)
            record_tool_patterns(event)
          end
        end
        identity = extract_caller_identity(event)
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
        @mutex.synchronize { @tool_patterns.transform_values(&:dup) }
      end

      def tool_patterns_for(identity)
        @mutex.synchronize { (@identity_tool_patterns[identity] || {}).transform_values(&:dup) }
      end

      def learned_data_for(identity)
        @mutex.synchronize do
          prefs = @user_prefs[identity] || {}
          {
            routing_preference: prefs[:routing]&.dup,
            tool_predictions: top_tools_for_identity(identity)
          }
        end
      end

      def erase_partner!(identity:)
        @mutex.synchronize do
          @user_prefs.delete(identity)
          @identity_tool_patterns.delete(identity)
        end
      end

      def reset!
        @mutex.synchronize do
          @user_prefs.clear
          @tool_patterns.clear
          @identity_tool_patterns.clear
        end
      end

      private

      def extract_caller_identity(event)
        rb = event.dig(:caller, :requested_by) || {}
        return nil unless rb[:type].to_s == 'human'

        identity = rb[:principal_id] || rb[:identity]
        identity.to_s unless identity.to_s.empty?
      end

      def record_routing_preference(event)
        identity = extract_caller_identity(event)
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
        identity = extract_caller_identity(event)
        tools = event[:tools_used] || []
        tools.each do |tool|
          name = tool[:name] || tool['name']
          next unless name

          patterns = identity ? (@identity_tool_patterns[identity] ||= {}) : @tool_patterns
          patterns[name] ||= { count: 0, last_used: nil }
          patterns[name][:count] += 1
          patterns[name][:last_used] = event[:timestamp]
        end
      end

      def top_tools_for_identity(identity)
        patterns = @identity_tool_patterns[identity] || {}
        patterns.sort_by { |_, value| -value[:count] }.first(10).to_h.transform_values(&:dup)
      end
    end
  end
end
