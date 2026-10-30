# frozen_string_literal: true

require 'forwardable'
require_relative 'bond_registry'

module Legion
  module Gaia
    # Persistence observes the same registry that ingress and advisory use.
    module BondTracker
      extend SingleForwardable

      def_delegators BondRegistry, :dirty?, :dirty_revision, :mark_clean!, :to_apollo_entries, :from_apollo
    end
  end
end
