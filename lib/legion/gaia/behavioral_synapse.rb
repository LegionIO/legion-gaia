# frozen_string_literal: true

require 'concurrent/hash'
require 'securerandom'
require 'legion/json'
require 'legion/logging/helper'

module Legion
  module Gaia
    module BehavioralSynapse # rubocop:disable Metrics/ModuleLength
      extend Legion::Logging::Helper

      TO_APOLLO_TAGS = %w[self-knowledge behavior].freeze

      # Vendored confidence math — identical constants to Legion::Extensions::Synapse::Helpers::Confidence.
      # At runtime we delegate to the real module if it is loaded.
      module Math
        STARTING_SCORES = { explicit: 0.7, emergent: 0.3, seeded: 0.5 }.freeze
        ADJUSTMENTS     = {
          success: 0.02,
          failure: -0.05,
          validation_failure: -0.03,
          consecutive_bonus: 0.05
        }.freeze
        DECAY_RATE = 0.998
        CONSECUTIVE_BONUS_THRESHOLD = 50
        AUTONOMY_RANGES = {
          observe: 0.0..0.3,
          filter: 0.3..0.6,
          transform: 0.6..0.8,
          autonomous: 0.8..1.0
        }.freeze
        E_WEIGHT = 3.0

        module_function

        def starting_score(origin)
          STARTING_SCORES.fetch(origin.to_sym, 0.3)
        end

        def adjust(confidence, event, consecutive_successes: 0)
          delta = ADJUSTMENTS.fetch(event.to_sym, 0.0)
          delta += ADJUSTMENTS[:consecutive_bonus] if consecutive_successes >= CONSECUTIVE_BONUS_THRESHOLD
          (confidence + delta).clamp(0.0, 1.0)
        end

        def decay(confidence, hours: 1)
          (confidence * (DECAY_RATE**hours)).clamp(0.0, 1.0)
        end

        def autonomy_mode(confidence)
          AUTONOMY_RANGES.find { |_mode, range| range.cover?(confidence) }&.first || :observe
        end
      end

      @store = Concurrent::Hash.new
      @dirty = false
      @mutex = Mutex.new

      module_function

      # --- Confidence math delegation ---

      def starting_score(origin)
        if defined?(Legion::Extensions::Synapse::Helpers::Confidence)
          Legion::Extensions::Synapse::Helpers::Confidence.starting_score(origin)
        else
          Math.starting_score(origin)
        end
      end

      def adjust(confidence, event, consecutive_successes: 0)
        if defined?(Legion::Extensions::Synapse::Helpers::Confidence)
          Legion::Extensions::Synapse::Helpers::Confidence.adjust(confidence, event,
                                                                  consecutive_successes: consecutive_successes)
        else
          Math.adjust(confidence, event, consecutive_successes: consecutive_successes)
        end
      end

      def decay_confidence(confidence, hours: 1)
        if defined?(Legion::Extensions::Synapse::Helpers::Confidence)
          Legion::Extensions::Synapse::Helpers::Confidence.decay(confidence, hours: hours)
        else
          Math.decay(confidence, hours: hours)
        end
      end

      def e_weight
        if defined?(Legion::Extensions::Synapse::Helpers::Confidence)
          Legion::Extensions::Synapse::Helpers::Confidence::E_WEIGHT
        else
          Math::E_WEIGHT
        end
      end

      # --- Public API ---

      def for(identity:, domain:)
        key = store_key(identity, domain)
        entry = @store[key]
        return nil unless entry

        apply_lazy_decay(entry)
      end

      def crystallize(identity:, domain:, directive:, evidence_trace_ids: [], origin: 'emergent')
        key = store_key(identity, domain)
        @mutex.synchronize do
          return @store[key] if @store[key]

          conf   = starting_score(origin.to_sym)
          now    = Time.now.utc
          entry  = {
            id: SecureRandom.uuid,
            identity: identity.to_s,
            domain: domain.to_s,
            origin: origin.to_s,
            confidence: conf,
            emotional_valence: 0.0,
            emotional_intensity: 0.0,
            consecutive_failures: 0,
            consecutive_successes: 0,
            directive: directive,
            evidence_trace_ids: Array(evidence_trace_ids),
            status: 'active',
            last_applied_at: nil,
            last_reinforced_at: now,
            created_at: now
          }
          @store[key] = entry
          @dirty = true
          log.info("[gaia] synapse crystallized identity=#{identity} domain=#{domain} origin=#{origin} conf=#{conf}")
          entry
        end
      end

      def record_outcome(id:, outcome:, multiplier: 1.0)
        @mutex.synchronize do
          entry = find_by_id(id)
          return { found: false } unless entry

          conf = entry[:confidence]
          base_event = outcome.to_sym
          new_conf = adjust(conf, base_event, consecutive_successes: entry[:consecutive_successes])

          # Apply multiplier to delta (scale the delta, not the raw confidence)
          raw_delta = new_conf - conf
          scaled_conf = (conf + (raw_delta * multiplier)).clamp(0.0, 1.0)

          if base_event == :success
            entry[:consecutive_successes] = entry[:consecutive_successes].to_i + 1
            entry[:consecutive_failures]  = 0
          elsif base_event == :failure
            entry[:consecutive_failures]  = entry[:consecutive_failures].to_i + 1
            entry[:consecutive_successes] = 0
          end

          entry[:confidence]          = scaled_conf
          entry[:last_reinforced_at]  = Time.now.utc
          @dirty = true

          apply_pain(entry) if entry[:consecutive_failures].to_i >= 3

          entry
        end
      end

      def all_for(identity:)
        prefix = "#{identity}:"
        @store.select { |key, _| key.start_with?(prefix) }.values
      end

      def erase_partner!(identity:)
        prefix = "#{identity}:"
        keys = @store.keys.select { |key| key.start_with?(prefix) }
        keys.each { |key| @store.delete(key) }
        @mutex.synchronize { @dirty = true } unless keys.empty?
        log.info("[gaia] BehavioralSynapse erased identity=#{identity} count=#{keys.size}")
        keys.size
      end

      def store
        @store
      end

      def reset!
        @mutex.synchronize do
          @store = Concurrent::Hash.new
          @dirty = false
        end
      end

      # --- TrackerPersistence support ---

      def dirty?
        @dirty == true
      end

      def mark_clean!
        @dirty = false
      end

      def to_apollo_entries
        @store.values.map do |entry|
          identity = entry[:identity]
          {
            content: Legion::JSON.dump(entry),
            tags: TO_APOLLO_TAGS + ["partner:#{identity}"],
            confidence: entry[:confidence] || 0.3,
            access_scope: 'local'
          }
        end
      end

      def from_apollo(store: nil)
        return unless store

        result = store.query(text: 'behavior', tags: TO_APOLLO_TAGS)
        return unless result.is_a?(Hash) && result[:success]

        count = 0
        result[:results]&.each do |entry|
          hydrate_apollo_entry(entry)
          count += 1
        rescue StandardError => e
          log.debug("[gaia] BehavioralSynapse skipped unparseable Apollo entry: #{e.message}")
        end
        log.info("[gaia] BehavioralSynapse hydrated from Apollo count=#{count}")
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.behavioral_synapse.from_apollo')
      end

      private

      def store_key(identity, domain)
        "#{identity}:#{domain}"
      end

      def find_by_id(id)
        @store.values.find { |entry| entry[:id] == id }
      end

      def apply_lazy_decay(entry)
        return entry unless entry[:last_reinforced_at]

        hours = (Time.now.utc - entry[:last_reinforced_at]) / 3600.0
        intensity = entry[:emotional_intensity].to_f
        effective_hours = hours / (1 + (intensity * e_weight))
        return entry if effective_hours < 0.001

        new_conf = decay_confidence(entry[:confidence], hours: effective_hours)
        @mutex.synchronize do
          entry[:confidence]         = new_conf
          entry[:last_reinforced_at] = Time.now.utc
          @dirty = true
        end
        entry
      end

      def apply_pain(entry)
        entry[:status]                = 'dampened'
        entry[:confidence]            = 0.29
        entry[:consecutive_failures]  = 0
        entry[:consecutive_successes] = 0
        log.warn("[gaia] synapse pain id=#{entry[:id]} domain=#{entry[:domain]} identity=#{entry[:identity]}")

        if defined?(Legion::Events) && Legion::Events.respond_to?(:emit)
          Legion::Events.emit('gaia.behavior.reverted',
                              id: entry[:id], identity: entry[:identity], domain: entry[:domain])
        end
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.behavioral_synapse.apply_pain', id: entry[:id])
      end

      def hydrate_apollo_entry(raw_entry)
        return unless raw_entry[:content].to_s.start_with?('{')

        parsed = Legion::JSON.load(raw_entry[:content])
        return unless parsed[:id] && parsed[:identity] && parsed[:domain]

        key = store_key(parsed[:identity], parsed[:domain])
        @mutex.synchronize do
          @store[key] = {
            id: parsed[:id],
            identity: parsed[:identity].to_s,
            domain: parsed[:domain].to_s,
            origin: parsed[:origin].to_s,
            confidence: parsed[:confidence].to_f,
            emotional_valence: parsed[:emotional_valence].to_f,
            emotional_intensity: parsed[:emotional_intensity].to_f,
            consecutive_failures: parsed[:consecutive_failures].to_i,
            consecutive_successes: parsed[:consecutive_successes].to_i,
            directive: parsed[:directive],
            evidence_trace_ids: Array(parsed[:evidence_trace_ids]),
            status: parsed[:status].to_s,
            last_applied_at: parsed[:last_applied_at],
            last_reinforced_at: parse_time(parsed[:last_reinforced_at]),
            created_at: parse_time(parsed[:created_at])
          }
        end
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError
        nil
      end

      module_function :store_key, :find_by_id, :apply_lazy_decay, :apply_pain, :hydrate_apollo_entry, :parse_time

      # Wrapper class that satisfies TrackerPersistence interface
      class Tracker
        def dirty?
          BehavioralSynapse.dirty?
        end

        def mark_clean!
          BehavioralSynapse.mark_clean!
        end

        def to_apollo_entries
          BehavioralSynapse.to_apollo_entries
        end

        def from_apollo(store: nil)
          BehavioralSynapse.from_apollo(store: store)
        end
      end
    end
  end
end
