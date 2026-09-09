# Shared building blocks of the three statistics pages (SLA, ticket, AI):
# time bucketing by day/week/month/year, gapless bucket lists, mean/median/
# percentile and the hour/weekday histograms.
#
# Everything works in local server time (getlocal), consistent with
# BusinessHours: background jobs run under UTC and would otherwise shift buckets
# and "busiest hours" by the UTC offset.
#
# Two usage styles:
#   - module functions: StatisticsSupport.bucket_key(time, 'week'), .mean(arr) ...
#   - mixin (include StatisticsSupport): private bucket_key(time), ordered_buckets,
#     mean, median reading @period / @date_from / @date_to of the including class.
module RedmineExpertHelpdesk
  module StatisticsSupport
    PERIODS = %w[day week month year].freeze

    # Unknown periods fall back to month.
    def normalize_period(period)
      PERIODS.include?(period.to_s) ? period.to_s : 'month'
    end

    def local(time)
      time.respond_to?(:getlocal) ? time.getlocal : time.to_time
    end

    # Bucket key of a point in time in local time (day/week/month/year).
    def bucket_key(time, period)
      t = local(time)
      case period
      when 'day'  then t.strftime('%Y-%m-%d')
      when 'week' then t.strftime('%G-W%V')
      when 'year' then t.strftime('%Y')
      else             t.strftime('%Y-%m')
      end
    end

    def bucket_label(key, period)
      period == 'month' ? Date.strptime(key, '%Y-%m').strftime('%m/%Y') : key
    end

    # Ordered list of all buckets between the two dates (including empty ones),
    # as [key, label] pairs, so bar charts have no gaps.
    def ordered_buckets(date_from, date_to, period)
      seen = {}
      date = date_from
      while date <= date_to
        key = bucket_key(date.to_time, period)
        seen[key] ||= bucket_label(key, period)
        date += 1
      end
      seen.to_a
    end

    # Rounded to integer; nil on empty input.
    def mean(arr)
      return nil if arr.empty?

      (arr.sum.to_f / arr.size).round
    end

    def median(arr)
      return nil if arr.empty?

      sorted = arr.sort
      mid = sorted.size / 2
      sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round
    end

    # Linear interpolation (0..100); nil on empty input.
    def percentile(arr, pct)
      return nil if arr.empty?

      sorted = arr.sort
      rank   = pct / 100.0 * (sorted.size - 1)
      lower  = sorted[rank.floor]
      upper  = sorted[rank.ceil]
      (lower + (upper - lower) * (rank - rank.floor)).round
    end

    # 24 counters, index = local hour.
    def hour_histogram(times)
      counts = Array.new(24, 0)
      times.each { |t| counts[local(t).hour] += 1 }
      counts
    end

    # 7 counters, index 0 = Monday .. 6 = Sunday (ISO weekdays).
    def weekday_histogram(times)
      counts = Array.new(7, 0)
      times.each { |t| counts[((local(t).wday + 6) % 7)] += 1 }
      counts
    end

    # Callable as StatisticsSupport.xyz(...); the instance copies below are
    # replaced by the arity-reduced mixin versions where names overlap.
    module_function :normalize_period, :local, :bucket_key, :bucket_label, :ordered_buckets,
                    :mean, :median, :percentile, :hour_histogram, :weekday_histogram

    # --- Mixin part (private instance methods, read @period/@date_from/@date_to) ----

    private

    def bucket_key(time)
      StatisticsSupport.bucket_key(time, @period)
    end

    def bucket_label(key)
      StatisticsSupport.bucket_label(key, @period)
    end

    def ordered_buckets
      @ordered_buckets ||= StatisticsSupport.ordered_buckets(@date_from, @date_to, @period)
    end

    def mean(arr)
      StatisticsSupport.mean(arr)
    end

    def median(arr)
      StatisticsSupport.median(arr)
    end

    def percentile(arr, pct)
      StatisticsSupport.percentile(arr, pct)
    end
  end
end
