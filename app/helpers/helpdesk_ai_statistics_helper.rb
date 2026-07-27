# View-Helfer fuer die KI-Statistik (Zahlen-/Dauer-/Quoten-Formatierung).
module HelpdeskAiStatisticsHelper
  # Ganzzahl mit Tausendertrennung; nil -> Strich.
  def hd_ai_number(value)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if value.nil?

    number_with_delimiter(value.to_i)
  end

  # Latenz in ms als "X ms" / "X.Y s"; nil -> Strich.
  def hd_ai_latency(ms)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if ms.nil?

    ms = ms.to_i
    ms < 1000 ? "#{ms} ms" : "#{(ms / 1000.0).round(1)} s"
  end

  # Quote (0..100) als "X %"; nil -> Strich.
  def hd_ai_ratio(pct)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if pct.nil?

    "#{pct} %"
  end

  # Lokalisierter Name eines Anfragetyps (summary, kb_extract, ...).
  def hd_ai_type_label(type)
    l("label_helpdesk_ai_stats_type_#{type}", :default => type.to_s)
  end

  # ISO-Wochentagsname (1=Mo .. 7=So) aus der Redmine-Lokalisierung.
  def hd_ai_weekday_name(iso_wday)
    day_name((iso_wday % 7)) # Redmine day_name: 0=So..6=Sa
  end
end
