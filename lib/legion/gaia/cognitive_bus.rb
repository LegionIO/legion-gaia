# frozen_string_literal: true

require 'legion/logging/helper'

module Legion
  module Gaia
    # The CognitiveBus is the shared signal substrate through which all
    # cognitive processes communicate. It implements competitive broadcasting:
    # processes submit signals with precision-weighted salience, and only the
    # top N signals win workspace access (consciousness). The rest run in
    # subconscious mode.
    #
    # Neuromodulators control who gets heard: acetylcholine gates attention,
    # norepinephrine controls global arousal, dopamine boosts reward signals,
    # serotonin modulates social signal weighting.
    class CognitiveBus
      include Legion::Logging::Helper

      DEFAULT_BROADCAST_SLOTS = 3

      class Signal
        attr_accessor :status, :salience
        attr_reader :type, :data, :precision, :source, :created_at

        def initialize(type:, data:, precision:, salience:, source:, status: :pending)
          @type      = type
          @data      = data
          @precision = precision
          @salience  = salience
          @source    = source
          @status    = status
          @created_at = Time.now.utc
        end

        def weighted_salience
          @salience * @precision
        end

        def to_h
          {
            type: @type,
            data: @data,
            precision: @precision,
            salience: @salience,
            source: @source,
            status: @status,
            weighted: weighted_salience.round(4)
          }
        end
      end

      def initialize(broadcast_slots: DEFAULT_BROADCAST_SLOTS)
        @mutex             = Mutex.new
        @broadcast_slots   = broadcast_slots
        @signals           = []
        @iteration         = 0
        @winners           = []
        @losers            = []
        @history           = []
        @max_history       = 200
      end

      # ── Signal Submission ───────────────────────────────────────────

      # A process submits a signal with precision-weighted salience.
      # type: symbol describing signal category (:prediction_error, :reward, :social, etc.)
      # data: arbitrary payload hash
      # precision: 0.0-1.0, how much to trust this signal (set by neuromodulators)
      # salience: 0.0-1.0, raw importance magnitude
      # source: which process submitted this signal
      def submit(type:, data:, precision:, salience:, source:)
        signal = Signal.new(
          type: type,
          data: data,
          precision: precision.clamp(0.0, 1.0),
          salience: salience.clamp(0.0, 1.0),
          source: source
        )

        @mutex.synchronize { @signals << signal }
        log.debug("[bus] submit type=#{type} source=#{source} precision=#{precision.round(3)} " \
                  "salience=#{salience.round(3)} weighted=#{signal.weighted_salience.round(3)}")
        signal
      end

      # ── Propagation (Winner-Take-Most) ──────────────────────────────

      # Run competitive broadcasting: sort signals by weighted salience,
      # apply neuromodulator weighting, select winners.
      #
      # neuromodulators should be a hash with :dopamine, :norepinephrine,
      # :serotonin, :acetylcholine, :oxytocin (each 0.0-1.0 level).
      def propagate(neuromodulators: {})
        @mutex.synchronize do
          @iteration += 1
          @winners   = []
          @losers    = []

          return propagation_result if @signals.empty?

          # Apply neuromodulator weighting to salience
          apply_neuromodulation(@signals, neuromodulators)

          # Sort by weighted salience (descending)
          ranked = @signals.sort_by { |s| -s.weighted_salience }

          # Winner-take-most
          @winners = ranked.first(@broadcast_slots)
          @winners.each { |s| s.status = :broadcast }

          @losers = ranked - @winners
          @losers.each { |s| s.status = :suppressed }

          # Record and clear
          record_iteration
          @signals.clear

          log.debug("[bus] iterate##{@iteration} signals=#{ranked.size} " \
                    "winners=#{@winners.size} losers=#{@losers.size} " \
                    "max_weighted=#{ranked.first&.weighted_salience&.round(3) || 0}")

          propagation_result
        end
      end

      # ── State ───────────────────────────────────────────────────────

      def max_prediction_error
        @mutex.synchronize do
          __max_prediction_error_unlocked
        end
      end

      def snapshot
        @mutex.synchronize do
          {
            iteration: @iteration,
            pending: @signals.map(&:to_h),
            last_winners: @winners.map(&:to_h),
            last_losers: @losers.map(&:to_h),
            max_error: __max_prediction_error_unlocked
          }
        end
      end

      def converged?(threshold: 0.05)
        @mutex.synchronize { __max_prediction_error_unlocked } < threshold
      end

      def iteration
        @mutex.synchronize { @iteration }
      end

      def pending_count
        @mutex.synchronize { @signals.size }
      end

      def winners
        @mutex.synchronize { @winners.dup }
      end

      def losers
        @mutex.synchronize { @losers.dup }
      end

      def history(limit: 50)
        @mutex.synchronize { @history.last(limit).dup }
      end

      def reset
        @mutex.synchronize do
          @signals.clear
          @winners.clear
          @losers.clear
        end
      end

      # ── Private ─────────────────────────────────────────────────────

      private

      def __max_prediction_error_unlocked
        @signals.select { |s| s.type == :prediction_error }
                .map { |s| s.data.is_a?(Hash) ? (s.data[:magnitude] || s.data[:error] || 0.0) : s.salience }
                .max || 0.0
      end

      def apply_neuromodulation(signals, neuromodulators)
        ach = neuromodulators[:acetylcholine]   || 0.5
        ne  = neuromodulators[:norepinephrine]  || 0.5
        da  = neuromodulators[:dopamine]        || 0.5
        ser = neuromodulators[:serotonin]       || 0.5
        oxt = neuromodulators[:oxytocin]        || 0.5

        signals.each do |signal|
          # Acetylcholine: global attention gate (applies to everything)
          signal.salience *= (0.5 + (ach * 0.5))

          # Norepinephrine: boosts urgency/emergency signals
          signal.salience *= (0.5 + (ne * 0.5)) if %i[prediction_error urgency emergency].include?(signal.type)

          # Dopamine: boosts reward/prediction-error with positive RPE
          signal.salience *= (0.5 + (da * 0.5)) if %i[reward prediction_error].include?(signal.type)

          # Serotonin: boosts social signals
          signal.salience *= (0.5 + (ser * 0.5)) if %i[social bond theory_of_mind].include?(signal.type)

          # Oxytocin: boosts in-group trust signals
          signal.salience *= (0.5 + (oxt * 0.5)) if %i[social bond trust].include?(signal.type)

          # Recalculate weighted salience after modulation
          signal.salience = [signal.salience, 1.0].min
        end
      end

      def propagation_result
        {
          iteration: @iteration,
          winners: @winners.map(&:to_h),
          losers: @losers.map(&:to_h),
          winner_count: @winners.size,
          loser_count: @losers.size,
          max_weighted: @winners.first&.weighted_salience&.round(4) || 0.0
        }
      end

      def record_iteration
        entry = {
          iteration: @iteration,
          total_signals: @signals.size,
          winners: @winners.map { |s| { source: s.source, type: s.type, weighted: s.weighted_salience.round(4) } },
          max_error: __max_prediction_error_unlocked.round(4)
        }
        @history << entry
        @history.shift while @history.size > @max_history
      end
    end
  end
end
