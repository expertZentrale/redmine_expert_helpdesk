require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die reinen Aggregations-Helfer der SLA-Statistik
# (Mittelwert/Median/Bucket-Schluessel). Die DB-gestuetzte Aggregation (to_h)
# wird manuell/funktional geprueft.
class SlaStatisticsTest < ActiveSupport::TestCase
  Stats = RedmineExpertHelpdesk::SlaStatistics

  def test_mean_rounds_to_integer
    assert_nil Stats.mean([])
    assert_equal 10, Stats.mean([10])
    assert_equal 20, Stats.mean([10, 20, 30])
    assert_equal 15, Stats.mean([10, 20])       # 15.0 -> 15
    assert_equal 12, Stats.mean([10, 11, 15])   # 12.0 -> 12
  end

  def test_median_odd_and_even
    assert_nil Stats.median([])
    assert_equal 20, Stats.median([30, 10, 20])          # ungerade
    assert_equal 25, Stats.median([10, 20, 30, 40])      # gerade -> (20+30)/2
    assert_equal 15, Stats.median([20, 10])              # unsortiert
  end

  def test_bucket_key_per_period
    t = Time.local(2026, 7, 8, 9, 26) # Mittwoch, KW28
    assert_equal '2026-07-08', Stats.bucket_key(t, 'day')
    assert_equal '2026-07',    Stats.bucket_key(t, 'month')
    assert_equal '2026',       Stats.bucket_key(t, 'year')
    assert_equal '2026-W28',   Stats.bucket_key(t, 'week')
    # Unbekannte Periode faellt auf Monat zurueck
    assert_equal '2026-07',    Stats.bucket_key(t, 'bogus')
  end

  def test_bucket_key_uses_local_time
    # 07:26 UTC == 09:26 lokal (Sommerzeit); Tag bleibt der 08.
    utc = Time.utc(2026, 7, 8, 7, 26)
    assert_equal '2026-07-08', Stats.bucket_key(utc, 'day')
  end
end
