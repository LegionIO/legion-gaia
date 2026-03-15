# frozen_string_literal: true

module Legion
  module Gaia
    class NotificationGate
      class ScheduleEvaluator
        DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze

        def initialize(schedule: [])
          @schedule = normalize_schedule(schedule)
        end

        def quiet?(at: Time.now)
          @schedule.any? { |window| matches_window?(at, window) }
        end

        private

        def normalize_schedule(schedule)
          schedule.map do |entry|
            entry = entry.transform_keys(&:to_sym)
            days = Array(entry[:days]).map { |d| DAY_NAMES.index(d.to_s.downcase) }.compact
            { days: days, start: entry[:start], end: entry[:end], all_day: entry[:all_day], timezone: entry[:timezone] }
          end
        end

        def matches_window?(time, window)
          local = localize(time, window[:timezone])
          day_index = local.wday
          return false unless window[:days].include?(day_index)
          return true if window[:all_day]

          in_time_range?(local, window[:start], window[:end])
        end

        def in_time_range?(time, start_str, end_str)
          return false unless start_str && end_str

          current = (time.hour * 60) + time.min
          start_min = parse_time(start_str)
          end_min = parse_time(end_str)

          if start_min <= end_min
            current >= start_min && current < end_min
          else
            current >= start_min || current < end_min
          end
        end

        def parse_time(str)
          parts = str.to_s.split(':')
          (parts[0].to_i * 60) + parts[1].to_i
        end

        def localize(time, timezone)
          return time unless timezone

          offset = tz_offset(timezone)
          offset ? time.getlocal(offset) : time
        end

        def tz_offset(timezone)
          return nil unless timezone

          offsets = {
            'America/Chicago' => '-06:00', 'America/New_York' => '-05:00',
            'America/Denver' => '-07:00', 'America/Los_Angeles' => '-08:00',
            'UTC' => '+00:00', 'America/Phoenix' => '-07:00'
          }
          offsets[timezone]
        end
      end
    end
  end
end
