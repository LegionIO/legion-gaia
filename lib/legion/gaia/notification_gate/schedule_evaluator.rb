# frozen_string_literal: true

module Legion
  module Gaia
    class NotificationGate
      class ScheduleEvaluator
        DAY_NAMES = %w[sun mon tue wed thu fri sat].freeze

        # Standard (non-DST) offsets for known IANA zone names.
        # Zones that observe DST have two entries; zones that don't have one.
        STANDARD_OFFSETS = {
          'America/New_York' => '-05:00', 'America/Chicago' => '-06:00',
          'America/Denver' => '-07:00', 'America/Los_Angeles' => '-08:00',
          'America/Phoenix' => '-07:00', 'America/Anchorage' => '-09:00',
          'Pacific/Honolulu' => '-10:00', 'America/Halifax' => '-04:00',
          'America/Toronto' => '-05:00', 'America/Vancouver' => '-08:00',
          'UTC' => '+00:00', 'Europe/London' => '+00:00',
          'Europe/Paris' => '+01:00', 'Europe/Berlin' => '+01:00',
          'Europe/Rome' => '+01:00', 'Europe/Madrid' => '+01:00',
          'Europe/Amsterdam' => '+01:00', 'Europe/Stockholm' => '+01:00',
          'Europe/Helsinki' => '+02:00', 'Europe/Moscow' => '+03:00',
          'Asia/Kolkata' => '+05:30', 'Asia/Tokyo' => '+09:00',
          'Asia/Shanghai' => '+08:00', 'Asia/Singapore' => '+08:00',
          'Asia/Dubai' => '+04:00', 'Asia/Seoul' => '+09:00',
          'Australia/Sydney' => '+10:00', 'Australia/Melbourne' => '+10:00',
          'Pacific/Auckland' => '+12:00'
        }.freeze

        # DST adjustments (+1 hour relative to standard) for zones that observe DST.
        DST_ZONES = %w[
          America/New_York America/Chicago America/Denver America/Los_Angeles
          America/Anchorage America/Halifax America/Toronto America/Vancouver
          Europe/London Europe/Paris Europe/Berlin Europe/Rome Europe/Madrid
          Europe/Amsterdam Europe/Stockholm Europe/Helsinki
          Australia/Sydney Australia/Melbourne Pacific/Auckland
        ].freeze

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
          return tzinfo_offset(timezone) if defined?(TZInfo)

          base = STANDARD_OFFSETS[timezone]
          return nil unless base

          dst_active? && DST_ZONES.include?(timezone) ? dst_shift(base) : base
        end

        def tzinfo_offset(timezone)
          hours = TZInfo::Timezone.get(timezone).current_period.utc_total_offset / 3600.0
          sign = hours.negative? ? '-' : '+'
          abs_h = hours.abs.to_i
          abs_m = ((hours.abs % 1) * 60).round
          format('%<sign>s%<h>02d:%<m>02d', sign: sign, h: abs_h, m: abs_m)
        rescue StandardError
          nil
        end

        def dst_shift(offset_str)
          sign = offset_str[0]
          parts = offset_str[1..].split(':').map(&:to_i)
          base_minutes = (parts[0] * 60) + parts[1]
          signed_minutes = (sign == '-' ? -base_minutes : base_minutes) + 60
          abs_total = signed_minutes.abs
          new_sign = signed_minutes.negative? ? '-' : '+'
          format('%<sign>s%<h>02d:%<m>02d', sign: new_sign, h: abs_total / 60, m: abs_total % 60)
        end

        def dst_active?
          m = Time.now.utc.month
          m.between?(3, 11)
        end
      end
    end
  end
end
