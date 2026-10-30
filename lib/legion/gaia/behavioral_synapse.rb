# frozen_string_literal: true

require 'concurrent/hash'
require 'securerandom'
require 'legion/json'
require 'legion/logging/helper'
require 'time'
require 'forwardable'
require_relative 'bond_registry'

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
      @revision = 0
      @clean_revision = 0
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
        @mutex.synchronize do
          return nil if BondRegistry.blocked?(identity: identity)

          entry = @store[store_key(identity, domain)]
          return nil unless entry

          apply_lazy_decay(entry)
          snapshot(entry)
        end
      end

      def crystallize(identity:, domain:, directive:, evidence_trace_ids: [], origin: 'emergent')
        key = store_key(identity, domain)
        @mutex.synchronize do
          return nil if BondRegistry.blocked?(identity: identity)
          return snapshot(@store[key]) if @store[key]

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
            directive: snapshot(directive),
            evidence_trace_ids: snapshot(Array(evidence_trace_ids)),
            status: 'active',
            last_applied_at: nil,
            last_reinforced_at: now,
            created_at: now
          }
          @store[key] = entry
          @revision += 1
          log.info("[gaia] synapse crystallized identity=#{identity} domain=#{domain} origin=#{origin} conf=#{conf}")
          snapshot(entry)
        end
      end

      def record_outcome(id:, identity:, outcome:, multiplier: 1.0)
        @mutex.synchronize do
          return { found: false } if BondRegistry.blocked?(identity: identity)

          entry = find_by_id(id)
          return { found: false } unless entry && entry[:identity] == identity.to_s

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
          @revision += 1

          apply_pain(entry) if entry[:consecutive_failures].to_i >= 3

          snapshot(entry)
        end
      end

      def all_for(identity:)
        @mutex.synchronize do
          return [] if BondRegistry.blocked?(identity: identity)

          @store.values.select { |entry| entry[:identity] == identity.to_s }.map { |entry| snapshot(entry) }
        end
      end

      def erase_partner!(identity:)
        @mutex.synchronize do
          keys = @store.keys.select { |key| @store[key][:identity] == identity.to_s }
          keys.each { |key| @store.delete(key) }
          @revision += 1 unless keys.empty?
          keys.size
        end
      end

      def reset!
        @mutex.synchronize do
          @store = Concurrent::Hash.new
          @revision = 0
          @clean_revision = 0
        end
      end

      # --- TrackerPersistence support ---

      def dirty?
        @mutex.synchronize { @revision != @clean_revision }
      end

      def dirty_revision
        @mutex.synchronize { @revision }
      end

      def mark_clean!(revision: dirty_revision)
        @mutex.synchronize { @clean_revision = revision if @revision == revision }
      end

      def to_apollo_entries
        @mutex.synchronize do
          @store.values.filter_map do |entry|
            next if BondRegistry.blocked?(identity: entry[:identity])

            identity_key = TrackerPersistence.identity_tag(identity: entry[:identity])
            { content: Legion::JSON.dump(entry.merge(identity_key: identity_key)),
              tags: TO_APOLLO_TAGS + [identity_key,
                                      "d:#{Digest::SHA256.hexdigest(entry[:domain])[0, 62]}"],
              confidence: entry[:confidence], access_scope: 'private' }
          end
        end
      end

      def from_apollo(store: nil)
        return false unless store

        records = TrackerPersistence.entries_for(store: store, tags: TO_APOLLO_TAGS)
        records.sort_by { |entry| TrackerPersistence.record_order(entry: entry) }.each do |entry|
          hydrate_apollo_entry(entry)
        rescue StandardError => e
          log.warn("BehavioralSynapse skipped invalid state: #{e.class}")
        end
        true
      rescue StandardError => e
        handle_exception(e, level: :warn, operation: 'gaia.behavioral_synapse.from_apollo')
        false
      end

      private

      def store_key(identity, domain)
        [identity.to_s, domain.to_s]
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

        entry[:confidence] = decay_confidence(entry[:confidence], hours: effective_hours)
        entry[:last_reinforced_at] = Time.now.utc
        @revision += 1
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
        parsed = Legion::JSON.load(raw_entry[:content])
        return unless parsed.is_a?(Hash) && parsed[:id] && parsed[:identity] && parsed[:domain]
        return if BondRegistry.blocked?(identity: parsed[:identity])

        identity_key = TrackerPersistence.identity_tag(identity: parsed[:identity])
        return if parsed.key?(:identity_key) && parsed[:identity_key] != identity_key

        entry = deserialize_entry(parsed: parsed)
        key = store_key(entry[:identity], entry[:domain])
        @mutex.synchronize { @store[key] = entry }
      end

      def deserialize_entry(parsed:)
        entry = parsed.slice(:id, :directive)
        %i[identity domain origin status].each { |key| entry[key] = parsed[key].to_s }
        %i[confidence emotional_valence emotional_intensity].each do |key|
          entry[key] = Float(parsed[key] || 0)
          raise ArgumentError, 'non-finite behavior evidence' unless entry[key].finite?
        end
        %i[consecutive_failures consecutive_successes].each do |key|
          entry[key] = Integer(parsed[key] || 0)
          raise ArgumentError, 'negative behavior evidence' if entry[key].negative?
        end
        raise ArgumentError, 'invalid behavior confidence' unless entry[:confidence].between?(0.0, 1.0)

        %i[last_applied_at last_reinforced_at created_at].each { |key| entry[key] = parse_time(parsed[key]) }
        entry[:evidence_trace_ids] = Array(parsed[:evidence_trace_ids])
        entry
      end

      def parse_time(value)
        return value if value.is_a?(Time)
        return nil if value.nil?

        Time.parse(value.to_s)
      rescue ArgumentError, TypeError => e
        log.warn("BehavioralSynapse invalid timestamp: #{e.class}")
        raise
      end

      def snapshot(value)
        case value
        when Hash then value.transform_values { |item| snapshot(item) }
        when Array then value.map { |item| snapshot(item) }
        when String, Time then value.dup
        else value
        end
      end

      module_function :store_key, :find_by_id, :apply_lazy_decay, :apply_pain,
                      :hydrate_apollo_entry, :deserialize_entry, :parse_time, :snapshot

      class Tracker
        extend Forwardable

        def_delegators BehavioralSynapse, :dirty?, :dirty_revision, :mark_clean!, :to_apollo_entries, :from_apollo
      end
    end
  end
end
