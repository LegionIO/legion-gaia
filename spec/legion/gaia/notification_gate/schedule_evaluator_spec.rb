# frozen_string_literal: true

RSpec.describe Legion::Gaia::NotificationGate::ScheduleEvaluator do
  # March 18, 2026 is a Wednesday
  # Weekday evening schedule: 21:00-07:00 CT (Mon-Fri), timezone America/Chicago
  let(:weekday_evening_schedule) do
    [
      {
        days: %w[mon tue wed thu fri],
        start: '21:00',
        end: '07:00',
        timezone: 'America/Chicago'
      }
    ]
  end

  # All-day weekend schedule: Sat-Sun
  let(:all_day_weekend_schedule) do
    [
      {
        days: %w[sat sun],
        all_day: true,
        timezone: 'America/Chicago'
      }
    ]
  end

  describe '#quiet?' do
    context 'with weekday evening schedule (21:00-07:00 CT, Mon-Fri)' do
      subject(:evaluator) { described_class.new(schedule: weekday_evening_schedule) }

      it 'returns true for Wednesday at 23:00 CT (within quiet window)' do
        time = Time.new(2026, 3, 18, 23, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be true
      end

      it 'returns false for Wednesday at 14:00 CT (outside quiet window)' do
        time = Time.new(2026, 3, 18, 14, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be false
      end

      it 'returns true for Thursday at 05:00 CT (overnight wrap, before end)' do
        # March 19, 2026 is Thursday
        time = Time.new(2026, 3, 19, 5, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be true
      end

      it 'returns false for Saturday at 23:00 CT (not in weekday schedule)' do
        # March 21, 2026 is Saturday
        time = Time.new(2026, 3, 21, 23, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be false
      end
    end

    context 'with all-day weekend schedule (Sat-Sun)' do
      subject(:evaluator) { described_class.new(schedule: all_day_weekend_schedule) }

      it 'returns true for Saturday at 14:00' do
        # March 21, 2026 is Saturday
        time = Time.new(2026, 3, 21, 14, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be true
      end

      it 'returns false for Monday at 14:00' do
        # March 23, 2026 is Monday
        time = Time.new(2026, 3, 23, 14, 0, 0, '-06:00')
        expect(evaluator.quiet?(at: time)).to be false
      end
    end

    context 'with empty schedule' do
      subject(:evaluator) { described_class.new(schedule: []) }

      it 'returns false' do
        expect(evaluator.quiet?).to be false
      end
    end

    context 'with non-US timezone (Fix 5: expanded tz table)' do
      subject(:evaluator) do
        described_class.new(schedule: [{
                              days: %w[mon tue wed thu fri],
                              start: '23:00',
                              end: '07:00',
                              timezone: 'Europe/London'
                            }])
      end

      it 'returns true for Wednesday at 23:30 UTC (London standard time, within window)' do
        # March 18, 2026 is Wednesday — London is UTC+0 in standard time
        time = Time.new(2026, 3, 18, 23, 30, 0, '+00:00')
        expect(evaluator.quiet?(at: time)).to be true
      end

      it 'returns false for Wednesday at 14:00 UTC (outside quiet window)' do
        time = Time.new(2026, 3, 18, 14, 0, 0, '+00:00')
        expect(evaluator.quiet?(at: time)).to be false
      end
    end

    context 'with Tokyo timezone (Fix 5: Asia zones)' do
      subject(:evaluator) do
        described_class.new(schedule: [{
                              days: %w[mon tue wed thu fri],
                              start: '22:00',
                              end: '08:00',
                              timezone: 'Asia/Tokyo'
                            }])
      end

      it 'returns true for Wednesday at 23:00 JST (within window)' do
        # JST is UTC+9, so 23:00 JST = 14:00 UTC
        time = Time.new(2026, 3, 18, 14, 0, 0, '+00:00')
        expect(evaluator.quiet?(at: time)).to be true
      end
    end

    context 'with unknown timezone' do
      subject(:evaluator) do
        described_class.new(schedule: [{
                              days: %w[mon tue wed thu fri],
                              start: '22:00',
                              end: '08:00',
                              timezone: 'Mars/Olympus_Mons'
                            }])
      end

      it 'falls back to UTC when timezone is unknown' do
        # Falls back to the time as-is when offset is nil
        time = Time.new(2026, 3, 18, 23, 0, 0, '+00:00')
        expect { evaluator.quiet?(at: time) }.not_to raise_error
      end
    end
  end
end
