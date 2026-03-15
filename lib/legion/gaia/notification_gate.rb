# frozen_string_literal: true

require_relative 'notification_gate/behavioral_evaluator'
require_relative 'notification_gate/delay_queue'
require_relative 'notification_gate/presence_evaluator'
require_relative 'notification_gate/schedule_evaluator'

module Legion
  module Gaia
    class NotificationGate
      PRIORITY_VALUES = { critical: 1.0, urgent: 0.8, normal: 0.5, low: 0.2, ambient: 0.0 }.freeze

      attr_reader :behavioral_evaluator, :presence_evaluator, :schedule_evaluator, :delay_queue

      def initialize(settings: {})
        notification_settings = settings[:notifications] || {}
        @enabled = notification_settings[:enabled] != false
        @priority_override = notification_settings[:priority_override] || :urgent

        schedule = notification_settings.dig(:quiet_hours, :schedule) || []
        quiet_enabled = notification_settings.dig(:quiet_hours, :enabled) != false
        @schedule_evaluator = ScheduleEvaluator.new(schedule: quiet_enabled ? schedule : [])

        max_size = notification_settings[:delay_queue_max] || 100
        max_delay = notification_settings[:max_delay] || 14_400
        @delay_queue = DelayQueue.new(max_size: max_size, max_delay: max_delay)
        @presence_evaluator = PresenceEvaluator.new
        @behavioral_evaluator = BehavioralEvaluator.new
      end

      def evaluate(frame)
        return :deliver unless @enabled
        return :deliver if priority_overrides?(frame)
        return :delay if @schedule_evaluator.quiet?

        priority = frame.metadata[:priority] || :normal
        return :delay unless @presence_evaluator.delivery_allowed?(priority: priority)
        return :delay unless @behavioral_evaluator.should_deliver?(priority: priority)

        :deliver
      end

      def update_behavioral(arousal: nil, idle_seconds: nil)
        @behavioral_evaluator.update_arousal(arousal) if arousal
        @behavioral_evaluator.update_idle_seconds(idle_seconds) if idle_seconds
      end

      def update_presence(availability:, activity: nil)
        @presence_evaluator.update(availability: availability, activity: activity)
      end

      def enqueue(frame)
        @delay_queue.enqueue(frame)
      end

      def process_delayed
        expired = @delay_queue.drain_expired
        deliverable = expired.map { |e| e[:frame] }

        unless @schedule_evaluator.quiet?
          flushed = @delay_queue.flush
          deliverable.concat(flushed.map { |e| e[:frame] })
        end

        deliverable
      end

      def flush
        @delay_queue.flush.map { |e| e[:frame] }
      end

      def pending_count
        @delay_queue.size
      end

      private

      def priority_overrides?(frame)
        priority = frame.metadata[:priority] || :normal
        frame_value = PRIORITY_VALUES[priority] || PRIORITY_VALUES[:normal]
        override_value = PRIORITY_VALUES[@priority_override] || PRIORITY_VALUES[:urgent]
        frame_value >= override_value
      end
    end
  end
end
