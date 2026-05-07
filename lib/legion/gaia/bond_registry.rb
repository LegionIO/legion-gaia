# frozen_string_literal: true

require 'legion/logging/helper'
require 'concurrent/hash'

module Legion
  module Gaia
    module BondRegistry
      extend Legion::Logging::Helper

      @bonds = Concurrent::Hash.new

      module_function

      def register(identity, bond: nil, role: nil, priority: :normal, channel_identity: nil,
                   preferred_channel: nil, last_channel: nil)
        effective_bond = (bond || role || :unknown).to_sym
        @bonds[identity.to_s] = {
          identity: identity.to_s,
          bond: effective_bond,
          role: effective_bond,
          priority: priority.to_sym,
          since: Time.now.utc,
          channel_identity: channel_identity&.to_s,
          preferred_channel: preferred_channel&.to_sym,
          last_channel: last_channel&.to_sym
        }
        log.info("BondRegistry registered identity=#{identity} bond=#{effective_bond} priority=#{priority}")
      end

      def bond(identity)
        entry = @bonds[identity.to_s]
        entry ? entry[:bond] : :unknown
      end

      def role(identity)
        bond(identity)
      end

      # Returns the channel-native identity for the given principal identity.
      # Falls back to the principal identity itself when no channel_identity was stored.
      # Proactive delivery paths MUST use this method to avoid sending messages
      # to a UUID that channel APIs (Teams, Slack) do not recognize.
      def channel_identity(identity)
        entry = @bonds[identity.to_s]
        return nil unless entry

        entry[:channel_identity] || entry[:identity]
      end

      def partner?(identity)
        bond(identity) == :partner
      end

      def all_bonds
        @bonds.values
      end

      def record_channel(identity, channel_id:, channel_identity: nil)
        entry = @bonds[identity.to_s]
        return nil unless entry

        channel = channel_id&.to_sym
        entry[:last_channel] = channel if channel
        entry[:preferred_channel] ||= channel if channel
        entry[:channel_identity] ||= channel_identity.to_s if channel_identity
        entry
      end

      # Returns the single best partner bond entry using deterministic selection:
      #   1. Prefer entries that have an explicit channel_identity stored (§9.6 guarantee)
      #   2. Then prefer entries with priority: :primary
      #   3. Otherwise return the earliest-registered entry (sort by :since, then :identity)
      # Sorting by :since then :identity ensures a stable result regardless of Concurrent::Hash
      # enumeration order, which is not guaranteed.
      def partner_entry
        partners = @bonds.values.select { |b| b[:bond] == :partner }
        return nil if partners.empty?

        sorted = partners.sort_by { |b| [b[:since], b[:identity]] }
        sorted.find { |b| b[:channel_identity] } ||
          sorted.find { |b| b[:priority] == :primary } ||
          sorted.first
      end

      def hydrate_from_apollo(store: nil)
        return unless store

        result = store.query(text: 'partner', tags: %w[self-knowledge])
        return unless result.is_a?(Hash) && result[:success] && result[:results]&.any?

        result[:results].each do |entry|
          content = entry[:content].to_s
          next unless content.match?(/partner/i)

          identities = extract_identity_keys(content)
          priority = content.match?(/primary/i) ? :primary : :normal
          channel_identity = extract_channel_identity(content)
          preferred_channel = extract_channel(content, 'preferred')
          last_channel = extract_channel(content, 'last')

          identities.each do |id|
            register(id, bond: :partner, priority: priority, channel_identity: channel_identity,
                         preferred_channel: preferred_channel, last_channel: last_channel)
          end
        end
        log.info("BondRegistry hydrated entries=#{result[:results].size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.hydrate_from_apollo')
      end

      def reset!
        @bonds = Concurrent::Hash.new
        log.debug('BondRegistry reset')
      end

      def extract_identity_keys(content)
        match = content.match(/identity\s*keys?[:\s]+([^\n]+)/i)
        return [] unless match

        match[1].split(/[,\s]+/).map(&:strip).reject(&:empty?)
      end

      def extract_channel_identity(content)
        match = content.match(/channel[_\s-]*identity[:\s]+([^\n]+)/i)
        first_match_value(match)
      end

      def extract_channel(content, kind)
        match = content.match(/#{kind}[_\s-]*channel[:\s]+([^\n]+)/i)
        first_match_value(match)
      end

      def first_match_value(match)
        return nil unless match

        match[1].split(/[,\s]+/).first&.strip
      end

      private_class_method :extract_identity_keys, :extract_channel_identity, :extract_channel, :first_match_value
    end
  end
end
