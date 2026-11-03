# frozen_string_literal: true

module Legion
  module Gaia
    module VisibleGrowth
      module_function

      # In-memory deduplication sets — reset on restart is intentional (worst case: fires twice)
      @acknowledged_milestones = Set.new
      @graduated_identities    = Set.new
      @onboarded_identities    = Set.new
      @mutex                   = Mutex.new

      TIER_LABELS = {
        observe: 'noticing patterns',
        filter: 'adjusting my approach',
        transform: 'actively shaping my responses',
        autonomous: 'applying this response preference consistently'
      }.freeze

      DOMAIN_PHRASES = {
        'brevity' => 'shorter answers',
        'verbosity' => 'longer, more detailed answers',
        'tone' => 'the tone',
        'format' => 'the format',
        'code' => 'code style',
        'detail' => 'the level of detail'
      }.freeze

      # Called when a synapse confidence crosses into a new autonomy tier.
      # Fires ONCE per (identity, domain, tier transition).
      #
      # @param identity [String]
      # @param domain   [String]
      # @param new_mode [Symbol] :observe | :filter | :transform | :autonomous
      # @param old_mode [Symbol]
      # @return [String, nil] acknowledgment message, or nil if already fired
      def milestone_acknowledgment(identity:, domain:, new_mode:, old_mode:)
        return nil if identity.to_s.empty?

        key = [identity.to_s, domain.to_s, old_mode.to_s, new_mode.to_s]
        @mutex.synchronize do
          return nil if @acknowledged_milestones.include?(key)

          @acknowledged_milestones.add(key)
        end

        phrase = domain_phrase(domain)
        tier_desc = TIER_LABELS.fetch(new_mode.to_sym, new_mode.to_s)

        "I've noticed you prefer #{phrase} — I'm now #{tier_desc}. Tell me if I've got that wrong."
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.milestone_acknowledgment')
        nil
      end

      # Called when pain fires (3 consecutive failures → dampened status).
      #
      # @param identity [String] partner receiving the acknowledgment
      # @param domain   [String]
      # @return [String]
      def pain_revert_acknowledgment(domain:, identity:)
        return nil if identity.to_s.empty?

        phrase = domain_phrase(domain)
        "I've been getting #{phrase} wrong — I've reset that. What works for you?"
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.pain_revert_acknowledgment')
        "I reset something that wasn't working — what would you prefer?"
      end

      # Called at imprint graduation (imprint window closes). Fires once per identity.
      #
      # @param identity [String]
      # @return [String, nil]
      def graduation_acknowledgment(identity:)
        return nil if identity.to_s.empty?

        @mutex.synchronize do
          return nil if @graduated_identities.include?(identity.to_s)

          @graduated_identities.add(identity.to_s)
        end

        "I've had more chances to learn how we work together. Please keep correcting assumptions that don't fit."
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.graduation_acknowledgment')
        nil
      end

      # Onboarding honesty — first frame at imprint open. Plain language about what's happening.
      # Fires once per identity.
      #
      # @param identity [String]
      # @return [String, nil] content string for OutputFrame, or nil if already sent
      def onboarding_frame(identity:)
        return nil if identity.to_s.empty?

        @mutex.synchronize do
          return nil if @onboarded_identities.include?(identity.to_s)

          @onboarded_identities.add(identity.to_s)
        end

        build_onboarding_text(identity: identity)
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.onboarding_frame')
        nil
      end

      # Epistemic honesty surface — returns a hedge/qualifier to append to a response, or nil.
      # Returns nil when confident (should be most of the time post-imprint).
      #
      # @param identity [String]
      # @param domain   [String, nil] current exchange domain, if known
      # @return [String, nil]
      def epistemic_qualifier(identity:, domain: nil)
        return nil if identity.to_s.empty?

        imprint_active = imprint_active_for?(identity: identity)
        synapse = domain ? Legion::Gaia::BehavioralSynapse.for(identity: identity.to_s, domain: domain.to_s) : nil

        return imprint_qualifier(identity: identity) if imprint_active
        return observe_qualifier(domain) if synapse_observe_tier?(synapse)

        nil
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.epistemic_qualifier')
        nil
      end

      # Reset in-memory state (for tests)
      def reset!
        @mutex.synchronize do
          @acknowledged_milestones = Set.new
          @graduated_identities    = Set.new
          @onboarded_identities    = Set.new
        end
      end

      # --- private helpers ---

      def domain_phrase(domain)
        DOMAIN_PHRASES.fetch(domain.to_s, domain.to_s.tr('_', ' '))
      end

      def imprint_active_for?(identity:)
        state = Legion::Gaia::Disclosure.fetch_imprint_state(identity: identity.to_s)
        state.is_a?(Hash) && state[:active] == true
      end

      def imprint_observation_count(identity:)
        state = Legion::Gaia::Disclosure.fetch_imprint_state(identity: identity.to_s)
        state[:observations_count] if state.is_a?(Hash)
      end

      def imprint_qualifier(identity:)
        count = imprint_observation_count(identity: identity)
        return "I'm still figuring out how you like things — was this right?" if count.nil? || count < 5

        "I'm still learning your style — let me know if this missed."
      end

      def synapse_observe_tier?(synapse)
        return false unless synapse.is_a?(Hash)

        Legion::Gaia::BehavioralSynapse::Math.autonomy_mode(synapse[:confidence].to_f) == :observe
      end

      def observe_qualifier(domain)
        "I have a hunch about #{domain_phrase(domain)} — tell me if I'm off."
      end

      def build_onboarding_text(identity:)
        lines = [
          "I'll be learning as we work together — what you prefer, how you like information, " \
          'what lands and what misses.',
          'Selected context may be sent to the configured model provider; ' \
          'storage and retention depend on this deployment.',
          'You can ask to inspect or end this relationship. Deletion reports cover the stores GAIA can actually erase.'
        ]

        bond = Legion::Gaia::BondRegistry.bond(identity.to_s)
        lines << "You're the partner on this node, so I'll pay closer attention." if bond == :partner

        lines.join(' ')
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.build_onboarding_text')
        "I'm learning as we go. You can inspect what I use, correct it, or ask to end this relationship."
      end

      def log_quietly(exception, operation)
        return unless defined?(Legion::Logging)

        Legion::Logging.debug("[gaia] #{operation} unavailable: #{exception.class}")
      end

      module_function :domain_phrase, :imprint_active_for?, :imprint_observation_count,
                      :imprint_qualifier, :synapse_observe_tier?, :observe_qualifier,
                      :build_onboarding_text, :log_quietly
    end
  end
end
