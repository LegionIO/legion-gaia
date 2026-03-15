# frozen_string_literal: true

module Legion
  module Gaia
    class NotificationGate
      class PresenceEvaluator
        PRESENCE_THRESHOLDS = {
          'Available' => :ambient,
          'Busy' => :urgent,
          'Away' => :urgent,
          'BeRightBack' => :urgent,
          'DoNotDisturb' => :critical,
          'Offline' => :critical
        }.freeze

        PRIORITY_ORDER = { critical: 4, urgent: 3, normal: 2, low: 1, ambient: 0 }.freeze

        attr_reader :availability, :activity, :updated_at

        def initialize
          @availability = nil
          @activity = nil
          @updated_at = nil
        end

        def update(availability:, activity: nil)
          @availability = availability
          @activity = activity
          @updated_at = Time.now.utc
        end

        def delivery_allowed?(priority: :normal)
          return true unless @availability

          min_priority = PRESENCE_THRESHOLDS[@availability] || :ambient
          priority_rank(priority) >= priority_rank(min_priority)
        end

        def stale?(max_age: 120)
          return true unless @updated_at

          (Time.now.utc - @updated_at) > max_age
        end

        private

        def priority_rank(priority)
          PRIORITY_ORDER[priority] || PRIORITY_ORDER[:normal]
        end
      end
    end
  end
end
