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
        autonomous: 'acting on this without asking'
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
        key = "#{identity}:#{domain}:#{old_mode}->#{new_mode}"
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
      # @param identity [String] (unused, reserved for future per-identity routing)
      # @param domain   [String]
      # @return [String]
      def pain_revert_acknowledgment(domain:, identity: nil) # rubocop:disable Lint/UnusedMethodArgument
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
        @mutex.synchronize do
          return nil if @graduated_identities.include?(identity.to_s)

          @graduated_identities.add(identity.to_s)
        end

        "I feel like I know how you work now — I'll ask less and do more. Correct me if I drift."
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
        imprint_active = imprint_active_for?
        synapse = domain ? Legion::Gaia::BehavioralSynapse.for(identity: identity.to_s, domain: domain.to_s) : nil

        return imprint_qualifier if imprint_active
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

      def imprint_active_for?
        return false unless defined?(Legion::Extensions::Coldstart)
        return false unless Legion::Extensions::Coldstart.respond_to?(:connected?) &&
                            Legion::Extensions::Coldstart.connected?

        bootstrap = Legion::Extensions::Coldstart::Helpers::Bootstrap.instance
        bootstrap.respond_to?(:imprint_active?) && bootstrap.imprint_active?
      rescue StandardError
        false
      end

      def imprint_observation_count
        return nil unless defined?(Legion::Extensions::Coldstart)

        bootstrap = Legion::Extensions::Coldstart::Helpers::Bootstrap.instance
        bootstrap.respond_to?(:observation_count) ? bootstrap.observation_count : nil
      rescue StandardError
        nil
      end

      def imprint_qualifier
        count = imprint_observation_count
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
          'Everything stays on this machine — nothing is sent anywhere else.',
          'You can end this at any time — your data goes with it, completely.'
        ]

        bond = Legion::Gaia::BondRegistry.bond(identity.to_s)
        lines << "You're the partner on this node, so I'll pay closer attention." if bond == :partner

        lines.join(' ')
      rescue StandardError => e
        VisibleGrowth.log_quietly(e, 'visible_growth.build_onboarding_text')
        "I'm learning as we go. Everything stays local. You can end this any time."
      end

      def log_quietly(exception, operation)
        return unless defined?(Legion::Logging)

        Legion::Logging.debug("[gaia] #{operation} rescued: #{exception.class}: #{exception.message}")
      end

      module_function :domain_phrase, :imprint_active_for?, :imprint_observation_count,
                      :imprint_qualifier, :synapse_observe_tier?, :observe_qualifier,
                      :build_onboarding_text, :log_quietly
    end
  end
end
