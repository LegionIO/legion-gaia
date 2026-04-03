# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    module BondRegistry
      extend Legion::Logging::Helper

      module_function

      def register(identity, role:, priority: :normal)
        @bonds ||= {}
        @bonds[identity.to_s] = { identity: identity.to_s, role: role.to_sym, priority: priority.to_sym,
                                  since: Time.now.utc }
        log.info("BondRegistry registered identity=#{identity} role=#{role} priority=#{priority}")
      end

      def partner?(identity)
        role(identity) == :partner
      end

      def role(identity)
        @bonds ||= {}
        entry = @bonds[identity.to_s]
        entry ? entry[:role] : :unknown
      end

      def all_bonds
        @bonds ||= {}
        @bonds.values
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

          identities.each { |id| register(id, role: :partner, priority: priority) }
        end
        log.info("BondRegistry hydrated entries=#{result[:results].size}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_registry.hydrate_from_apollo')
      end

      def reset!
        @bonds = {}
        log.debug('BondRegistry reset')
      end

      def extract_identity_keys(content)
        match = content.match(/identity\s*keys?[:\s]+([^\n]+)/i)
        return [] unless match

        match[1].split(/[,\s]+/).map(&:strip).reject(&:empty?)
      end
      private_class_method :extract_identity_keys
    end
  end
end
