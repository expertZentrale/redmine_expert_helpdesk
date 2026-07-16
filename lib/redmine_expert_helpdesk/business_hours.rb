# Geschaeftszeit-Rechner fuer die SLA-Uhren.
# Arbeitszeiten kommen aus HelpdeskProjectSetting: Wochentage (ISO, Mo=1..So=7)
# und eine Zeitspanne (HH:MM bis HH:MM). SLA-Zeiten laufen nur innerhalb
# dieser Fenster.
module RedmineExpertHelpdesk
  class BusinessHours
    MAX_LOOKAHEAD_DAYS = 400

    def initialize(setting)
      @days      = setting.sla_work_days_array
      @start_min = parse_hhmm(setting.sla_work_start, 8 * 60)
      @end_min   = parse_hhmm(setting.sla_work_end, 17 * 60)
      @end_min   = @start_min if @end_min < @start_min
    end

    # Geschaeftsminuten zwischen zwei Zeitpunkten (>= 0).
    def elapsed_minutes(from, to)
      return 0 if from.nil? || to.nil? || to <= from

      total = 0
      date  = from.getlocal.to_date
      while date <= to.getlocal.to_date
        if workday?(date)
          seg_start = [from, time_on(date, @start_min)].max
          seg_end   = [to,   time_on(date, @end_min)].min
          total += ((seg_end - seg_start) / 60).floor if seg_end > seg_start
        end
        date += 1
      end
      total
    end

    # Zeitpunkt, an dem +minutes+ Geschaeftsminuten ab +from+ verstrichen sind
    # (Faelligkeit). Liefert nil wenn keine Arbeitstage konfiguriert sind.
    def due_at(from, minutes)
      return nil if from.nil? || minutes.to_i <= 0 || @days.empty?

      remaining = minutes.to_i
      date   = from.getlocal.to_date
      cursor = from

      MAX_LOOKAHEAD_DAYS.times do
        if workday?(date)
          day_start = time_on(date, @start_min)
          day_end   = time_on(date, @end_min)
          seg_start = [cursor, day_start].max

          if seg_start < day_end
            available = ((day_end - seg_start) / 60).floor
            return seg_start + remaining * 60 if remaining <= available

            remaining -= available
          end
        end
        date  += 1
        cursor = time_on(date, 0)
      end
      nil
    end

    def workday?(date)
      @days.include?(date.cwday)
    end

    private

    def parse_hhmm(value, default_minutes)
      m = value.to_s.match(/\A(\d{1,2}):(\d{2})\z/)
      return default_minutes unless m

      [[m[1].to_i, 23].min * 60 + [m[2].to_i, 59].min, 0].max
    end

    # Zeitpunkt auf +date+ um +minutes_from_midnight+ in der LOKALEN Zeitzone des
    # Servers. Geschaeftszeiten (z. B. 08:00-17:00) sind lokale Buerozeiten und
    # muessen unabhaengig von der ambient Time.zone gelten: In Hintergrundjobs
    # (SLA-Cron) und fuer Benutzer ohne Zeitzonen-Einstellung ist Time.zone haeufig
    # UTC, wodurch die Buerozeiten faelschlich nach UTC verschoben wuerden
    # (z. B. 08:00 als 08:00 UTC = 10:00 lokal). Die Anzeige nutzt ebenfalls die
    # lokale Serverzeit, daher ist dies konsistent.
    def time_on(date, minutes_from_midnight)
      Time.local(date.year, date.month, date.day) + minutes_from_midnight * 60
    end
  end
end
