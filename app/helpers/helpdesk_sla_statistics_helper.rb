# View-Helfer fuer die SLA-Statistik (KPI-Zeitformat, Wochentagsnamen).
module HelpdeskSlaStatisticsHelper
  # Geschaeftsminuten als "Xh Ym" (oder "Ym"); nil -> Strich.
  def hd_stats_minutes(minutes)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if minutes.nil?

    m = minutes.to_i
    h, rest = m.divmod(60)
    h > 0 ? "#{h}h #{rest}m" : "#{rest}m"
  end

  # ISO-Wochentagsname (1=Mo .. 7=So) aus der Redmine-Lokalisierung.
  def hd_stats_weekday_name(iso_wday)
    day_name((iso_wday % 7)) # Redmine day_name: 0=So..6=Sa
  end
end
