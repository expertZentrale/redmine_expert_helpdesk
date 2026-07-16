require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den Geschaeftszeit-Rechner (Kernstueck der SLA-Berechnung).
# Arbeitszeiten: Mo-Fr 08:00-17:00 (Default-Stub).
class BusinessHoursTest < ActiveSupport::TestCase
  SettingStub = Struct.new(:sla_work_days_array, :sla_work_start, :sla_work_end)

  def setup
    @setting = SettingStub.new([1, 2, 3, 4, 5], '08:00', '17:00')
    @bh = RedmineExpertHelpdesk::BusinessHours.new(@setting)
  end

  # Montag, 6. Juli 2026 ist ein Montag
  # Eingaben in der lokalen Serverzeit bauen, passend zur Interpretation der
  # Geschaeftszeiten in BusinessHours#time_on (Time.local). Bewusst nicht
  # Time.zone.local, das in der Testumgebung meist UTC ist und die Buerozeiten
  # gegen die lokale Zeit verschieben wuerde.
  def monday(hhmm)
    h, m = hhmm.split(':').map(&:to_i)
    Time.local(2026, 7, 6, h, m)
  end

  def time_at(day, hhmm)
    h, m = hhmm.split(':').map(&:to_i)
    Time.local(2026, 7, day, h, m)
  end

  def test_elapsed_within_one_workday
    assert_equal 120, @bh.elapsed_minutes(monday('09:00'), monday('11:00'))
  end

  def test_elapsed_clamps_to_work_start
    # 06:00-09:00: nur 08:00-09:00 zaehlt
    assert_equal 60, @bh.elapsed_minutes(monday('06:00'), monday('09:00'))
  end

  def test_elapsed_clamps_to_work_end
    # 16:00-20:00: nur 16:00-17:00 zaehlt
    assert_equal 60, @bh.elapsed_minutes(monday('16:00'), monday('20:00'))
  end

  def test_elapsed_spans_multiple_days
    # Mo 16:00 -> Di 09:00 = 60 (Mo) + 60 (Di) = 120
    assert_equal 120, @bh.elapsed_minutes(monday('16:00'), time_at(7, '09:00'))
  end

  def test_elapsed_skips_weekend
    # Fr 10.7. 16:00 -> Mo 13.7. 09:00 = 60 + 60 = 120 (Sa/So zaehlen nicht)
    assert_equal 120, @bh.elapsed_minutes(time_at(10, '16:00'), time_at(13, '09:00'))
  end

  def test_elapsed_zero_outside_business_hours
    # Sa 11.7. komplett
    assert_equal 0, @bh.elapsed_minutes(time_at(11, '08:00'), time_at(11, '20:00'))
  end

  def test_elapsed_zero_for_inverted_range
    assert_equal 0, @bh.elapsed_minutes(monday('11:00'), monday('09:00'))
  end

  def test_due_at_same_day
    due = @bh.due_at(monday('09:00'), 60)
    assert_equal monday('10:00'), due
  end

  def test_due_at_spans_to_next_day
    # Mo 16:30 + 60min = 30min Mo + 30min Di -> Di 08:30
    due = @bh.due_at(monday('16:30'), 60)
    assert_equal time_at(7, '08:30'), due
  end

  def test_due_at_skips_weekend
    # Fr 10.7. 16:30 + 60min -> Mo 13.7. 08:30
    due = @bh.due_at(time_at(10, '16:30'), 60)
    assert_equal time_at(13, '08:30'), due
  end

  def test_due_at_start_outside_hours
    # Mo 06:00 + 60min -> Mo 09:00
    due = @bh.due_at(monday('06:00'), 60)
    assert_equal monday('09:00'), due
  end

  def test_due_at_start_on_weekend
    # Sa 11.7. 12:00 + 60min -> Mo 13.7. 09:00
    due = @bh.due_at(time_at(11, '12:00'), 60)
    assert_equal time_at(13, '09:00'), due
  end

  def test_due_at_nil_without_workdays
    bh = RedmineExpertHelpdesk::BusinessHours.new(SettingStub.new([], '08:00', '17:00'))
    assert_nil bh.due_at(monday('09:00'), 60)
  end

  def test_invalid_time_format_falls_back_to_defaults
    bh = RedmineExpertHelpdesk::BusinessHours.new(SettingStub.new([1, 2, 3, 4, 5], 'kaputt', ''))
    # Default 08:00-17:00 greift
    assert_equal 60, bh.elapsed_minutes(monday('07:00'), monday('09:00'))
  end
end
