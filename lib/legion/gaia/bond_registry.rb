# frozen_string_literal: true

require 'legion/json'
require 'legion/logging/helper'
require 'concurrent/hash'

module Legion
  module Gaia
    module BondRegistry # rubocop:disable Metrics/ModuleLength
      extend Legion::Logging::Helper

      TO_APOLLO_TAGS = %w[self-knowledge bond].freeze

      @bonds        = Concurrent::Hash.new
      @bond_states  = Concurrent::Hash.new
      @dirty        = false
      @mutex        = Mutex.new

      module_function

      # Register identity in the bond catalog.
      # Origin defaults to :provisional for partner bonds, nil for others.
      # rubocop:disable Metrics/ParameterLists
      def register(identity, bond: nil, role: nil, priority: :normal, channel_identity: nil,
                   preferred_channel: nil, last_channel: nil, origin: nil, strength: nil,
                   reinforcement_count: nil, last_reinforced: nil)
        # rubocop:enable Metrics/ParameterLists
        effective_bond = (bond || role || :unknown).to_sym
        origin         ||= effective_bond == :partner ? :provisional : nil
        strength       ||= 0.0
        @mutex.synchronize do
          @bonds[identity.to_s] = build_entry(
            identity,
            bond: effective_bond,
            priority: priority,
            channel_identity: channel_identity,
            preferred_channel: preferred_channel,
            last_channel: last_channel,
            origin: origin,
            strength: strength,
            reinforcement_count: reinforcement_count || 0,
            last_reinforced: last_reinforced
          )
          @dirty = true
        end
        log.info(
          "BondRegistry registered identity=#{identity} bond=#{effective_bond} " \
          "origin=#{origin} strength=#{strength}"
        )
      end

      def build_entry(identity, bond:, priority:, channel_identity:, preferred_channel:,
                      last_channel:, origin: nil, strength: 0.0, reinforcement_count: 0,
                      last_reinforced: nil)
        {
          identity: identity.to_s,
          bond: bond,
          role: bond,
          priority: priority.to_sym,
          since: Time.now.utc,
          channel_identity: channel_identity&.to_s,
          preferred_channel: preferred_channel&.to_sym,
          last_channel: last_channel&.to_sym,
          origin: origin,
          strength: strength,
          reinforcement_count: reinforcement_count,
          last_reinforced: last_reinforced
        }
      end

      def bond(identity)
        entry = @bonds[identity.to_s]
        entry ? entry[:bond] : :unknown
      end

      def role(identity)
        bond(identity)
      end

      # Returns the channel-native identity for the given principal identity.
      def channel_identity(identity)
        entry = @bonds[identity.to_s]
        return nil unless entry

        entry[:channel_identity] || entry[:identity]
      end

      # Partner check: must be :partner bond AND strength >= partner_threshold.
      def partner?(identity)
        entry = @bonds[identity.to_s]
        return false unless entry

        entry[:bond] == :partner && (entry[:strength] || 0) >= partner_threshold
      end

      def partner_threshold
        gaia_settings&.dig(:partner, :partner_threshold) || 0.6
      end

      def gaia_settings
        Legion::Gaia.settings
      rescue StandardError
        nil
      end

      def all_bonds
        @bonds.values
      end

      def record_channel(identity, channel_id:, channel_identity: nil)
        @mutex.synchronize do
          entry = @bonds[identity.to_s]
          return nil unless entry

          channel = channel_id&.to_sym
          updated = entry.merge(
            last_channel: channel || entry[:last_channel],
            preferred_channel: entry[:preferred_channel] || channel,
            channel_identity: entry[:channel_identity] || channel_identity&.to_s
          )
          @bonds[identity.to_s] = updated
          @dirty = true
          updated
        end
      end

      # Returns the single best partner bond entry.
      # Sorted by highest strength first, then channel_identity, priority, earliest.
      def partner_entry
        partners = @bonds.values.select do |b|
          b[:bond] == :partner && (b[:strength] || 0) >= partner_threshold
        end
        return nil if partners.empty?

        sorted = partners.sort_by { |b| [-b[:strength], b[:since], b[:identity]] }
        sorted.find { |b| b[:channel_identity] } ||
          sorted.find { |b| b[:priority] == :primary } ||
          sorted.first
      end

      # §12.3 reinforcement formula with diminishing returns.
      def reinforce(identity, direct_address: false, new_channel: false, multiplier: 1.0)
        identity = identity.to_s
        @mutex.synchronize do
          entry = @bonds[identity]
          return entry unless entry

          r              = gaia_settings&.dig(:partner, :r_amount) || 0.1
          weight         = 1.0
          weight        *= gaia_settings&.dig(:partner, :direct_address_weight) || 1.5 if direct_address
          weight        *= gaia_settings&.dig(:partner, :corroboration_weight) || 1.3 if new_channel

          delta          = r * (1 - (entry[:strength] || 0)) * weight * multiplier
          new_strength   = [(entry[:strength] || 0) + delta, 1.0].min

          entry[:strength]            = new_strength
          entry[:reinforcement_count] = (entry[:reinforcement_count] || 0) + 1
          entry[:last_reinforced]     = Time.now.utc
          @dirty                      = true

          # Provisional -> earned on threshold crossing
          if entry[:origin] == :provisional && new_strength >= partner_threshold
            entry[:origin] = :earned
            log.info(
              "[gaia] bond promoted identity=#{identity} strength=#{new_strength.round(3)} " \
              'origin=:earned'
            )
          end

          entry
        end
      end

      # Apply decay to all bond strengths (spec §12.3, IDENTITY class rate).
      def apply_decay
        rate = gaia_settings&.dig(:partner, :identity_decay_rate) || 0.002
        @mutex.synchronize do
          @bonds.each_value do |entry|
            next unless entry.key?(:strength) && entry[:strength] > 0.0

            entry[:strength] = (entry[:strength] * (1 - rate)).max(0.0)
          end
          @dirty = true
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.apply_decay')
      end

      # ---- Persistence (TrackerPattern) ----

      def dirty?
        @dirty == true
      end

      def mark_clean!
        @dirty = false
      end

      # Apollo-upsert shape for TrackerPersistence.
      def to_apollo_entries
        @bonds.values.map do |entry|
          {
            content: Legion::JSON.dump(entry),
            tags: TO_APOLLO_TAGS,
            confidence: entry[:strength] || 0.0,
            access_scope: 'local'
          }
        end
      end

      def from_apollo(store: nil)
        return unless store

        result = store.query(text: 'bond', tags: TO_APOLLO_TAGS)
        return unless result.is_a?(Hash) && result[:success]

        result[:results]&.each do |entry|
          parsed = Legion::JSON.load(entry[:content])
          next unless parsed[:identity]

          register(
            parsed[:identity],
            bond: parsed[:bond],
            priority: parsed[:priority] || :normal,
            channel_identity: parsed[:channel_identity],
            preferred_channel: parsed[:preferred_channel],
            last_channel: parsed[:last_channel],
            origin: :hydrated,
            strength: parsed[:strength] || 0.0,
            reinforcement_count: parsed[:reinforcement_count] || 0,
            last_reinforced: parsed[:last_reinforced]
          )
        rescue StandardError => e
          log.debug("[gaia] BondRegistry skipped unparseable Apollo entry: #{e.message}")
        end
        log.info("[gaia] BondRegistry hydrated from Apollo count=#{result[:results]&.size || 0}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.from_apollo')
      end

      # Hydrate from Apollo — structured JSON first, legacy markdown fallback.
      def hydrate_from_apollo(store: nil)
        return unless store

        json_hydrated = try_json_hydration(store)
        return if json_hydrated

        try_legacy_hydration(store)
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.hydrate_from_apollo')
      end

      def erase_partner!(identity:)
        erased = false
        @mutex.synchronize do
          erased = @bonds.delete(identity.to_s)
          @dirty = true if erased
        end
        log.info("[gaia] bond erased identity=#{identity}") if erased
        if defined?(Legion::Events) && Legion::Events.respond_to?(:emit)
          Legion::Events.emit('gaia.bond.erased', identity: identity)
        end
        { erased: !erased.nil?, identity: identity }
      end

      def set_bond_state(identity, state)
        @bond_states[identity.to_s] = state.to_sym
      end

      def bond_state(identity)
        @bond_states[identity.to_s]
      end

      def terminating?(identity)
        @bond_states[identity.to_s] == :terminating
      end

      def terminated?(identity)
        @bond_states[identity.to_s] == :terminated
      end

      def reset!
        @mutex.synchronize do
          @bonds = Concurrent::Hash.new
          @bond_states = Concurrent::Hash.new
          @dirty = false
        end
        log.debug('BondRegistry reset')
      end

      # ---- Private helpers ----

      def try_json_hydration(store) # rubocop:disable Naming/PredicateMethod
        result = store.query(text: 'bond', tags: TO_APOLLO_TAGS)
        return false unless result.is_a?(Hash) && result[:success]
        return false unless result[:results]&.any?

        count = 0
        result[:results].each { |e| count += 1 if hydrate_json_entry(e) }
        return false unless count.positive?

        log.info("[gaia] BondRegistry hydrated #{count} JSON entries")
        true
      end

      def hydrate_json_entry(entry)
        return unless entry[:content].to_s.start_with?('{')

        parsed = Legion::JSON.load(entry[:content])
        return unless parsed[:identity]

        register(
          parsed[:identity],
          bond: parsed[:bond],
          priority: parsed[:priority] || :normal,
          channel_identity: parsed[:channel_identity],
          preferred_channel: parsed[:preferred_channel],
          last_channel: parsed[:last_channel],
          origin: :hydrated,
          strength: parsed[:strength] || 0.0,
          reinforcement_count: parsed[:reinforcement_count] || 0,
          last_reinforced: parsed[:last_reinforced]
        )
      rescue StandardError => e
        log.debug("[gaia] BondRegistry skipped unparseable entry: #{e.message}")
      end

      def try_legacy_hydration(store)
        result = store.query(text: 'partner', tags: %w[self-knowledge])
        return unless result.is_a?(Hash) && result[:success] && result[:results]&.any?

        result[:results].each { |e| hydrate_legacy_entry(e) }
        log.info("[gaia] BondRegistry hydrated #{result[:results].size} legacy entries")
      end

      def hydrate_legacy_entry(entry)
        content = entry[:content].to_s
        return unless content.match?(/partner/i)

        identities = extract_identity_keys(content)
        return if identities.empty?

        priority = content.match?(/primary/i) ? :primary : :normal
        cid      = extract_channel_identity(content)
        pref     = extract_channel(content, 'preferred')
        last_c   = extract_channel(content, 'last')

        identities.each do |id|
          register(id, bond: :partner, priority: priority, channel_identity: cid,
                       preferred_channel: pref, last_channel: last_c)
        end
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

      private_class_method :build_entry, :extract_identity_keys, :extract_channel_identity,
                           :extract_channel, :first_match_value, :try_json_hydration,
                           :hydrate_json_entry, :try_legacy_hydration, :hydrate_legacy_entry
    end
  end
end
