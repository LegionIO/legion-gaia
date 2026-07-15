# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    # Per-identity bond evidence accumulator.
    # Tracks a 0..1 strength score that grows through observed interactions.
    # Supports provisional bonds (short-lived, capped at 0.5) and imprint-window acceleration.
    class BondStore
      include Legion::Logging::Helper

      # Evidence weight categories — sum to 1.0
      DEFAULT_WEIGHTS = {
        direct_address: 0.20,
        interaction_frequency: 0.15,
        response_latency: 0.10,
        content_depth: 0.15,
        sentiment: 0.15,
        consistency: 0.10,
        helpfulness: 0.10,
        shared_vulnerability: 0.05
      }.freeze

      # Bell thresholds — score crosses upward boundary
      DEFAULT_BELL_THRESHOLDS = [0.25, 0.50, 0.75, 0.90, 1.0].freeze

      # Max evidence entries retained per identity (ring buffer)
      MAX_EVIDENCE = 200

      # Default provisional TTL — 24 hours
      DEFAULT_PROVISIONAL_TTL = 24 * 3600

      # Maximum decay factor (floor) — score doesn't drop below 70% of raw
      DECAY_FLOOR = 0.7

      # Provisional strength ceiling until confirmed
      PROVISIONAL_CEILING = 0.5

      attr_reader :identity, :bond_role, :started_at, :raw_score, :evidence_log, :provisional_expires_at,
                  :provisional_ttl, :identity_principal_id, :identity_canonical_name, :identity_id

      def initialize(identity:, bond_role:, started_at: Time.now.utc, weights: DEFAULT_WEIGHTS,
                     bell_thresholds: DEFAULT_BELL_THRESHOLDS,
                     provisional_ttl: DEFAULT_PROVISIONAL_TTL)
        @identity = identity.to_s
        @bond_role = (bond_role || :unknown).to_sym
        @started_at = started_at
        @weights = weights
        @bell_thresholds = bell_thresholds
        @provisional_ttl = provisional_ttl

        @raw_score = 0.0
        @evidence_log = []
        @dirty = false
        @last_evidence_at = nil
        @provisional_expires_at = set_provisional_expiry!
        @crossed_bells = []
        @identity_principal_id = nil
        @identity_canonical_name = nil
        @identity_id = nil
      end

      # Accumulate evidence from an observation hash.
      # Returns the delta added to raw_score.
      def accumulate(observation, imprint_multiplier: 1.0)
        base_delta = extract_evidence_delta(observation)
        imprint = imprint_multiplier || 1.0
        delta = base_delta * imprint * diminishing_factor

        # Apply decay discount to incoming evidence (older = less impactful)
        return 0.0 if delta.zero?

        @raw_score = [@raw_score + delta, 1.0].min
        @last_evidence_at = Time.now.utc

        # Capture identity columns from observation
        @identity_principal_id ||= observation[:identity_principal_id]
        @identity_canonical_name ||= observation[:identity_canonical_name]
        @identity_id ||= observation[:identity_id]

        # Log evidence (ring buffer)
        log_entry = {
          timestamp: observation[:timestamp] || Time.now.utc,
          delta: delta.round(6),
          base_delta: base_delta.round(6),
          direct_address: observation[:direct_address] || false,
          content_length: observation[:content_length] || 0,
          channel: (observation[:channel] || :unknown).to_s
        }
        @evidence_log << log_entry
        @evidence_log.shift if @evidence_log.size > MAX_EVIDENCE

        @dirty = true
        log.debug("[bond] accumulate identity=#{@identity} delta=#{delta.round(6)} " \
                  "score=#{@raw_score.round(4)} multiplier=#{imprint}")
        delta
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_store.accumulate', identity: @identity)
        0.0
      end

      # Returns 0..1 strength, applying time decay and provisional cap.
      def strength
        decayed = apply_decay(@raw_score)

        if @bond_role == :provisional && @provisional_expires_at
          return 0.0 if Time.now.utc > @provisional_expires_at

          # Expired provisional transitions to unknown
          if Time.now.utc > @provisional_expires_at
            @bond_role = :unknown
            log.debug("[bond] provisional expired identity=#{@identity}")
          end
          return [decayed, PROVISIONAL_CEILING].min
        end

        decayed
      end

      # Check if a new strength value crosses any uncrossed bell threshold.
      # Returns list of newly crossed thresholds.
      def bell?(new_strength)
        new_bells = @bell_thresholds.select do |threshold|
          new_strength >= threshold && !@crossed_bells.include?(threshold)
        end
        @crossed_bells += new_bells if new_bells.any?
        new_bells
      end

      # Mark this provisional bond as confirmed (remove cap and expiry).
      def confirm!
        return unless @bond_role == :provisional

        old_role = @bond_role
        @bond_role = :partner
        @provisional_expires_at = nil
        @dirty = true
        log.info("[bond] confirmed provisional identity=#{@identity} role=#{old_role}->#{@bond_role}")
      end

      def provisional?
        @bond_role == :provisional
      end

      def dirty?
        @dirty
      end

      def mark_clean!
        @dirty = false
      end

      # Convert to Apollo upsert entries for persistence.
      def to_apollo_entries
        entries = []

        # Summary entry — current strength snapshot
        entries << {
          content: content_from_values,
          tags: %w[bond gaia bond_evidence],
          confidence: strength,
          access_scope: 'local',
          identity_canonical_name: @identity_canonical_name,
          identity_principal_id: @identity_principal_id,
          identity_id: @identity_id
        }

        # Evidence batch entries (last N entries since clean)
        entries += evidence_entries

        entries
      end

      # Reconstruct state from Apollo query results (hydration).
      def from_apollo(store:)
        result = store.query(text: "bond #{@identity}", tags: %w[bond gaia bond_evidence])
        return unless result.is_a?(Hash) && result[:success] && result[:results]

        result[:results].each do |entry|
          # Extract strength from confidence field
          raw_confidence = entry[:confidence] || 0.0
          @raw_score = [raw_confidence, 1.0].min if raw_confidence.is_a?(Numeric)

          # Extract identity columns
          @identity_principal_id ||= entry[:identity_principal_id]
          @identity_canonical_name ||= entry[:identity_canonical_name]
          @identity_id ||= entry[:identity_id]
        end
        @last_evidence_at = Time.now.utc
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.bond_store.from_apollo', identity: @identity)
      end

      private

      def extract_evidence_delta(observation)
        direct_addr_delta = direct_address_signal(observation) * @weights[:direct_address]
        content_depth_delta = content_depth_signal(observation) * @weights[:content_depth]
        latency_delta = latency_signal(observation) * @weights[:response_latency]

        direct_addr_delta + content_depth_delta + latency_delta
      end

      def direct_address_signal(observation)
        # Direct address is a strong signal — full weight
        observation[:direct_address] ? 0.02 : 0.0
      end

      def content_depth_signal(observation)
        length = (observation[:content_length] || 0).to_i
        # Normalize: 0-50=0.001, 50-200=0.003, 200-500=0.005, >500=0.007
        case length
        when 0..50 then 0.001
        when 51..200 then 0.003
        when 201..500 then 0.005
        else 0.007
        end
      end

      def latency_signal(observation)
        latency = observation[:latency]
        return 0.0 unless latency.is_a?(Numeric)

        # Shorter latency = better signal
        case latency
        when 0..5 then 0.004
        when 5..30 then 0.003
        when 30..120 then 0.002
        else 0.001
        end
      end

      def diminishing_factor
        # As raw_score approaches 1.0, each increment has less effect
        1.0 - @raw_score
      end

      def apply_decay(raw)
        return 0.0 unless @last_evidence_at

        elapsed_hours = (Time.now.utc - @last_evidence_at) / 3600.0
        decay_factor = [1.0 - (elapsed_hours * 0.001), DECAY_FLOOR].max
        (raw * decay_factor).round(6)
      end

      def set_provisional_expiry!
        return nil unless @bond_role == :provisional

        Time.now.utc + @provisional_ttl
      end

      def content_from_values
        Legion::JSON.dump({
                            type: 'bond_snapshot',
                            identity: @identity,
                            bond_role: @bond_role.to_s,
                            raw_score: @raw_score.round(6),
                            strength: strength.round(6),
                            evidence_count: @evidence_log.size,
                            started_at: @started_at.iso8601(3),
                            last_evidence_at: @last_evidence_at&.iso8601(3),
                            crossed_bells: @crossed_bells
                          })
      end

      def evidence_entries
        # Only flush recent evidence entries (last 10 for persistence efficiency)
        recent = @evidence_log.last(10)
        recent.each_with_index.map do |ev, idx|
          {
            content: content_from_single_evidence(ev, idx),
            tags: %w[bond gaia bond_evidence evidence_entry],
            confidence: ev[:delta].round(6),
            access_scope: 'local',
            identity_canonical_name: @identity_canonical_name,
            identity_principal_id: @identity_principal_id,
            identity_id: @identity_id
          }
        end
      end

      def content_from_single_evidence(evidence, idx)
        ts = evidence[:timestamp].respond_to?(:iso8601) ? evidence[:timestamp].iso8601(3) : nil
        Legion::JSON.dump({
                            type: 'bond_evidence_entry',
                            identity: @identity,
                            sequence: idx,
                            timestamp: ts,
                            delta: evidence[:delta],
                            base_delta: evidence[:base_delta],
                            direct_address: evidence[:direct_address],
                            content_length: evidence[:content_length],
                            channel: evidence[:channel]
                          })
      end
    end
  end
end
