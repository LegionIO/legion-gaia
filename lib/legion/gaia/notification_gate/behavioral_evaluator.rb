# frozen_string_literal: true

module Legion
  module Gaia
    class NotificationGate
      class BehavioralEvaluator
        PRIORITY_BASE_THRESHOLD = { critical: 0.0, urgent: 0.0, normal: 0.3, low: 0.5, ambient: 0.7 }.freeze
        THRESHOLD_MODIFIER = 0.3

        def initialize
          @arousal = nil
          @idle_seconds = nil
        end

        def update_arousal(value)
          @arousal = value.to_f.clamp(0.0, 1.0)
        end

        def update_idle_seconds(seconds)
          @idle_seconds = seconds.to_f
        end

        def notification_score
          signals = []
          signals << arousal_signal if @arousal
          signals << idle_signal if @idle_seconds

          return 1.0 if signals.empty?

          signals.sum / signals.size
        end

        def should_deliver?(priority: :normal)
          base = PRIORITY_BASE_THRESHOLD[priority] || PRIORITY_BASE_THRESHOLD[:normal]
          effective_threshold = base + ((1.0 - notification_score) * THRESHOLD_MODIFIER)
          priority_value(priority) >= effective_threshold
        end

        private

        def arousal_signal
          @arousal.clamp(0.0, 1.0)
        end

        def idle_signal
          max_idle = 3600.0
          [1.0 - (@idle_seconds / max_idle), 0.0].max
        end

        def priority_value(priority)
          { critical: 1.0, urgent: 0.8, normal: 0.5, low: 0.2, ambient: 0.0 }[priority] || 0.5
        end
      end
    end
  end
end
