# frozen_string_literal: true

require 'time'
require 'legion/json'
require 'legion/logging/helper'
require_relative 'tracker_persistence'
require_relative 'bond_persistence'

module Legion
  module Gaia
    module BondRegistry
      extend Legion::Logging::Helper
      extend BondPersistence

      TO_APOLLO_TAGS = %w[self-knowledge bond].freeze
      LIFECYCLE_TAGS = %w[gaia_lifecycle].freeze
      BLOCKED_STATES = %i[terminating terminated revoked].freeze

      @bonds = {}
      @bond_states = {}
      @revision = 0
      @clean_revision = 0
      @lifecycle_ready = true
      @mutex = Mutex.new

      module_function

      def register(identity, bond: nil, role: nil, **attributes)
        identity = identity.to_s
        raise ArgumentError, 'identity is required' if identity.empty?

        attributes = registration_attributes(**attributes)
        effective_bond = (bond || role || :unknown).to_sym
        @mutex.synchronize do
          return nil if blocked?(identity: identity)

          if (existing = @bonds[identity])
            update_registration(existing: existing, bond: effective_bond, attributes: attributes)
          else
            attributes[:origin] ||= :provisional if effective_bond == :partner
            @bonds[identity] = attributes.merge(identity: identity, bond: effective_bond, role: effective_bond,
                                                since: Time.now.utc)
          end
          @revision += 1
          snapshot(@bonds[identity])
        end
      end

      def entry(identity:)
        @mutex.synchronize { snapshot(@bonds[identity.to_s]) }
      end

      def bond(identity)
        return :unknown if blocked?(identity: identity)

        entry(identity: identity)&.dig(:bond) || :unknown
      end

      def role(identity)
        bond(identity)
      end

      def channel_identity(identity)
        return nil if blocked?(identity: identity)

        value = entry(identity: identity)
        value && (value[:channel_identity] || value[:identity])
      end

      def partner?(identity)
        return false if blocked?(identity: identity)

        value = entry(identity: identity)
        (value && value[:bond] == :partner && value[:strength].to_f >= partner_threshold) || false
      end

      def partner_threshold
        gaia_settings&.dig(:partner, :partner_threshold) || 0.6
      end

      def gaia_settings
        Legion::Gaia.settings
      end

      def all_bonds
        @mutex.synchronize { @bonds.values.map { |value| snapshot(value) } }
      end

      def record_channel(identity, channel_id:, channel_identity: nil)
        @mutex.synchronize do
          return nil if blocked?(identity: identity)

          value = @bonds[identity.to_s]
          return nil unless value

          value[:last_channel] = channel_id.to_sym if channel_id
          value[:preferred_channel] ||= channel_id&.to_sym
          value[:channel_identity] ||= channel_identity&.to_s
          @revision += 1
          snapshot(value)
        end
      end

      def partner_entry
        partners = all_bonds.select do |value|
          next false if blocked?(identity: value[:identity])

          value[:bond] == :partner && value[:strength].to_f >= partner_threshold
        end
        partners.sort_by! { |value| [-value[:strength], value[:since], value[:identity]] }
        partners.find { |value| value[:channel_identity] } || partners.find do |value|
          value[:priority] == :primary
        end || partners.first
      end

      def reinforce(identity, direct_address: false, new_channel: false, multiplier: 1.0)
        @mutex.synchronize do
          return nil if blocked?(identity: identity)

          value = @bonds[identity.to_s]
          return nil unless value

          weight = 1.0
          weight *= gaia_settings&.dig(:partner, :direct_address_weight) || 1.5 if direct_address
          weight *= gaia_settings&.dig(:partner, :corroboration_weight) || 1.3 if new_channel
          rate = gaia_settings&.dig(:partner, :r_amount) || 0.1
          value[:strength] = (value[:strength] + (rate * (1 - value[:strength]) * weight * multiplier)).clamp(0.0, 1.0)
          value[:reinforcement_count] += 1
          value[:last_reinforced] = Time.now.utc
          value[:origin] = :earned if value[:origin] == :provisional && value[:strength] >= partner_threshold
          @revision += 1
          snapshot(value)
        end
      end

      def apply_decay
        rate = gaia_settings&.dig(:partner, :identity_decay_rate) || 0.002
        @mutex.synchronize do
          @bonds.each_value do |value|
            next if blocked?(identity: value[:identity])

            value[:strength] = (value[:strength] * (1 - rate)).clamp(0.0, 1.0)
          end
          @revision += 1 unless @bonds.empty?
        end
      end

      def dirty?
        @mutex.synchronize { @revision != @clean_revision }
      end

      def dirty_revision
        @mutex.synchronize { @revision }
      end

      def mark_clean!(revision: dirty_revision)
        @mutex.synchronize { @clean_revision = revision if @revision == revision }
      end

      def lifecycle_identities
        @mutex.synchronize { @bond_states.keys.dup }
      end

      def erase_partner!(identity:)
        @mutex.synchronize do
          removed = @bonds.delete(identity.to_s)
          @revision += 1 if removed
          { erased: true, count: removed ? 1 : 0, durable: false }
        end
      end

      # In-memory barrier only. Privacy operations must call persist_lifecycle.
      def set_bond_state(identity, state)
        raise ArgumentError, 'invalid lifecycle barrier' unless BLOCKED_STATES.include?(state.to_sym)

        @mutex.synchronize { @bond_states[identity.to_s] = state.to_sym }
      end

      def bond_state(identity)
        @bond_states[identity.to_s]
      end

      def blocked?(identity:)
        !@lifecycle_ready || BLOCKED_STATES.include?(@bond_states[identity.to_s])
      end

      def lifecycle_ready?
        @lifecycle_ready == true
      end

      def mark_lifecycle_unavailable!
        @mutex.synchronize { @lifecycle_ready = false }
      end

      def terminating?(identity)
        @bond_states[identity.to_s] == :terminating
      end

      def terminated?(identity)
        @bond_states[identity.to_s] == :terminated
      end

      def reset!
        @mutex.synchronize do
          @bonds = {}
          @bond_states = {}
          @revision = 0
          @clean_revision = 0
          @lifecycle_ready = true
        end
      end

      def registration_attributes(priority: :normal, channel_identity: nil, preferred_channel: nil, last_channel: nil,
                                  origin: nil, strength: nil, reinforcement_count: nil, last_reinforced: nil)
        { priority: priority.to_sym, channel_identity: channel_identity&.to_s,
          preferred_channel: preferred_channel&.to_sym, last_channel: last_channel&.to_sym,
          origin: origin, strength: strength || 0.0, reinforcement_count: reinforcement_count || 0,
          last_reinforced: last_reinforced }
      end
      private_class_method :registration_attributes

      def update_registration(existing:, bond:, attributes:)
        existing[:channel_identity] ||= attributes[:channel_identity]
        existing[:preferred_channel] ||= attributes[:preferred_channel]
        existing[:last_channel] = attributes[:last_channel] if attributes[:last_channel]
        return unless existing[:bond] == :unknown && bond != :unknown

        existing[:bond] = bond
        existing[:role] = bond
        existing[:origin] = attributes[:origin] || (bond == :partner ? :provisional : nil)
        existing[:strength] = [existing[:strength], attributes[:strength]].max
      end
      private_class_method :update_registration

      def snapshot(value)
        value&.transform_values { |item| item.is_a?(String) || item.is_a?(Time) ? item.dup : item }
      end
      private_class_method :snapshot
    end
  end
end
