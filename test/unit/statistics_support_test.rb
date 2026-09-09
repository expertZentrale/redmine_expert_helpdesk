require File.expand_path('../../test_helper', __FILE__)

# Pure helpers shared by the statistics pages (buckets, mean/median/percentile,
# histograms). No DB.
class StatisticsSupportTest < ActiveSupport::TestCase
  S = RedmineExpertHelpdesk::StatisticsSupport

  def test_normalize_period
    assert_equal 'week',  S.normalize_period('week')
    assert_equal 'month', S.normalize_period('bogus')
    assert_equal 'month', S.normalize_period(nil)
  end

  def test_bucket_key_per_period
    t = Time.local(2026, 7, 8, 9, 26) # Wednesday, ISO week 28
    assert_equal '2026-07-08', S.bucket_key(t, 'day')
    assert_equal '2026-W28',   S.bucket_key(t, 'week')
    assert_equal '2026-07',    S.bucket_key(t, 'month')
    assert_equal '2026',       S.bucket_key(t, 'year')
  end

  def test_bucket_label_only_reformats_months
    assert_equal '07/2026',  S.bucket_label('2026-07', 'month')
    assert_equal '2026-W28', S.bucket_label('2026-W28', 'week')
  end

  def test_ordered_buckets_are_gapless_and_ordered
    buckets = S.ordered_buckets(Date.new(2026, 1, 30), Date.new(2026, 3, 1), 'month')
    assert_equal [['2026-01', '01/2026'], ['2026-02', '02/2026'], ['2026-03', '03/2026']], buckets
  end

  def test_mean_median_percentile
    assert_nil S.mean([])
    assert_equal 20, S.mean([10, 20, 30])
    assert_equal 15, S.mean([10, 20])
    assert_nil S.median([])
    assert_equal 20, S.median([30, 10, 20])
    assert_equal 25, S.median([10, 20, 30, 40])
    assert_nil S.percentile([], 95)
    assert_equal 4,  S.percentile([1, 2, 3, 4], 100)
    assert_equal 1,  S.percentile([1, 2, 3, 4], 0)
  end

  def test_histograms_use_local_time_and_iso_weekdays
    monday_9 = Time.local(2026, 7, 6, 9, 0) # Monday
    sunday_23 = Time.local(2026, 7, 12, 23, 30)
    hours = S.hour_histogram([monday_9, monday_9, sunday_23])
    assert_equal 2, hours[9]
    assert_equal 1, hours[23]
    days = S.weekday_histogram([monday_9, sunday_23])
    assert_equal 1, days[0]
    assert_equal 1, days[6]
  end

  def test_mixin_reads_instance_state
    klass = Class.new do
      include RedmineExpertHelpdesk::StatisticsSupport
      def initialize
        @period = 'day'
        @date_from = Date.new(2026, 1, 1)
        @date_to   = Date.new(2026, 1, 2)
      end

      def probe
        [bucket_key(Time.local(2026, 1, 1, 12)), ordered_buckets.map(&:first), mean([1, 2])]
      end
    end
    assert_equal ['2026-01-01', ['2026-01-01', '2026-01-02'], 2], klass.new.probe
    assert_not klass.new.respond_to?(:mean), 'mixin helpers stay private'
  end
end
