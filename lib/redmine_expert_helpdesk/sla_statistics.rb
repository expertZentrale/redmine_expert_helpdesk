# Aggregiert Kennzahlen fuer die SLA-Statistik-Seite eines Projekts.
#
# Basis: SLA-relevante Tickets (Helpdesk-Tickets mit HelpdeskTicketInfo, erstellt
# ab sla_enabled_at). Gruppierung nach Tag/Woche/Monat/Jahr; Zeit-Buckets und
# "Stosszeiten" verwenden die lokale Serverzeit (konsistent mit BusinessHours).
#
# Liefert reine Ruby-Datenstrukturen (to_h) ohne Rendering-Logik, damit die
# Aggregation isoliert testbar bleibt.
module RedmineExpertHelpdesk
  class SlaStatistics
    include StatisticsSupport

    PERIODS = StatisticsSupport::PERIODS

    # Eine ausgewertete Ticket-Zeile (Spalten-Reihenfolge = pluck unten).
    Row = Struct.new(:id, :created_on, :closed_on, :first_response_at,
                     :reaction_minutes, :solution_minutes,
                     :reaction_due_at, :reaction_warn_at,
                     :solution_due_at, :solution_warn_at)

    def initialize(project, period: 'month', date_from: nil, date_to: nil)
      @project = project
      @period  = StatisticsSupport.normalize_period(period)
      @date_to   = date_to   || Date.current
      @date_from = date_from || (@date_to - 30)
      @date_from, @date_to = @date_to, @date_from if @date_from > @date_to

      @setting = HelpdeskProjectSetting.for_project(project)
      @from_t  = @date_from.to_time            # lokale Mitternacht (Start inkl.)
      @to_t    = (@date_to + 1).to_time        # lokale Mitternacht Folgetag (Ende exkl.)
    end

    def to_h
      rows = load_rows
      {
        :period    => @period,
        :date_from => @date_from,
        :date_to   => @date_to,
        :totals    => totals(rows),
        :volume    => volume_series(rows),
        :avg       => averages(rows),
        :avg_trend => average_trend(rows),
        :compliance    => compliance(rows),
        :busiest_hours    => busiest_hours,
        :busiest_weekdays => busiest_weekdays
      }
    end

    private

    # SLA-relevante Tickets des Projekts, erstellt im gewaehlten Zeitraum.
    def base_scope
      scope = Issue
                .joins("INNER JOIN helpdesk_ticket_infos ti ON ti.issue_id = #{Issue.quoted_table_name}.id")
        .joins("INNER JOIN #{IssueStatus.quoted_table_name} st ON st.id = #{Issue.quoted_table_name}.status_id")
                .where(:project_id => @project.id)
      enabled_at = @setting.sla_enabled_at
      scope = scope.where("#{Issue.quoted_table_name}.created_on >= ?", enabled_at) if enabled_at
      scope
    end

    def load_rows
      base_scope
        .where("#{Issue.quoted_table_name}.created_on >= ? AND #{Issue.quoted_table_name}.created_on < ?", @from_t, @to_t)
        .pluck("#{Issue.quoted_table_name}.id",
               "#{Issue.quoted_table_name}.created_on",
               "#{Issue.quoted_table_name}.closed_on",
               'ti.first_response_at',
               'ti.reaction_business_minutes',
               'ti.solution_business_minutes',
               'ti.sla_reaction_due_at',
               'ti.sla_reaction_warn_at',
               'ti.sla_solution_due_at',
               'ti.sla_solution_warn_at',
               'st.is_closed')
        .map do |*cols, closed|
          row = Row.new(*cols)
          # Redmine keeps closed_on after a reopen; only a currently closed
          # status counts as closed here (same guard as Sla / IssuePatch).
          row.closed_on = nil unless closed
          row
        end
    end

    def totals(rows)
      closed = rows.count { |r| r.closed_on }
      # "Offen ueberschritten": nur OFFENE Tickets, deren Reaktions- oder
      # Loesungsuhr aktuell offen ueberschritten ist. Geschlossene Tickets zaehlen
      # hier nie (ihre Reaktionsuhr kann ohne erfasste Erstreaktion faelschlich als
      # offen erscheinen).
      breached_open = rows.count do |r|
        r.closed_on.nil? && (reaction_status(r) == :breached || solution_status(r) == :breached)
      end
      { :tickets => rows.size, :open => rows.size - closed,
        :closed => closed, :breached_open => breached_open }
    end

    # Erstellte je Bucket; geschlossene je Bucket (nur Tickets, die im Zeitraum
    # erstellt UND geschlossen wurden). Liefert eine geordnete Serie inkl. leerer
    # Buckets, damit die Balken luecklos sind.
    def volume_series(rows)
      created = Hash.new(0)
      closed  = Hash.new(0)
      rows.each do |r|
        created[bucket_key(r.created_on)] += 1
        if r.closed_on && r.closed_on >= @from_t && r.closed_on < @to_t
          closed[bucket_key(r.closed_on)] += 1
        end
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label, :created => created[key], :closed => closed[key] }
      end
    end

    def averages(rows)
      reaction = rows.select { |r| r.first_response_at && r.reaction_minutes }.map(&:reaction_minutes)
      solution = rows.select { |r| r.closed_on && r.solution_minutes }.map(&:solution_minutes)
      { :reaction_mean   => mean(reaction),   :reaction_median => median(reaction),
        :solution_mean   => mean(solution),   :solution_median => median(solution),
        :reaction_count  => reaction.size,    :solution_count  => solution.size }
    end

    def average_trend(rows)
      react = Hash.new { |h, k| h[k] = [] }
      solve = Hash.new { |h, k| h[k] = [] }
      rows.each do |r|
        key = bucket_key(r.created_on)
        react[key] << r.reaction_minutes if r.first_response_at && r.reaction_minutes
        solve[key] << r.solution_minutes if r.closed_on && r.solution_minutes
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label,
          :reaction => mean(react[key]), :solution => mean(solve[key]) }
      end
    end

    # Ampel-Zaehlung je Uhr plus Erfuellungsquote (nur abgeschlossene Uhren).
    def compliance(rows)
      { :reaction => clock_compliance(rows) { |r| reaction_status(r) },
        :solution => clock_compliance(rows) { |r| solution_status(r) } }
    end

    def clock_compliance(rows)
      counts = Hash.new(0)
      rows.each do |r|
        status = yield(r)
        next if status.nil?
        # Offene Uhr-Zustaende (laufend/Warnung/offen ueberschritten) nur fuer
        # OFFENE Tickets zaehlen. Bei geschlossenen Tickets ohne abgeschlossene Uhr
        # (z. B. nie beantwortet) ist das eine Tracking-Luecke, kein offener Verstoß.
        next if r.closed_on && [:running, :warning, :breached].include?(status)
        counts[status] += 1
      end
      met      = counts[:met]
      breached = counts[:breached_done]
      completed = met + breached
      {
        :met           => met,
        :breached_done => breached,
        :warning       => counts[:warning],
        :running       => counts[:running],
        :breached_open => counts[:breached],
        :completed     => completed,
        :met_ratio     => completed > 0 ? (met * 100.0 / completed).round(1) : nil
      }
    end

    def busiest_hours
      StatisticsSupport.hour_histogram(message_times)
    end

    # ISO-Wochentage 1=Mo .. 7=So.
    def busiest_weekdays
      StatisticsSupport.weekday_histogram(message_times)
    end

    # Zeitpunkte eingehender Nachrichten SLA-relevanter Tickets im Zeitraum.
    def message_times
      return @message_times if defined?(@message_times)

      scope = HelpdeskMessage.incoming
                .joins("INNER JOIN #{Issue.quoted_table_name} ON #{Issue.quoted_table_name}.id = #{HelpdeskMessage.quoted_table_name}.issue_id")
                .joins("INNER JOIN helpdesk_ticket_infos ti ON ti.issue_id = #{HelpdeskMessage.quoted_table_name}.issue_id")
                .where("#{Issue.quoted_table_name}.project_id = ?", @project.id)
      enabled_at = @setting.sla_enabled_at
      scope = scope.where("#{Issue.quoted_table_name}.created_on >= ?", enabled_at) if enabled_at

      time_expr = "COALESCE(#{HelpdeskMessage.quoted_table_name}.sent_at, #{HelpdeskMessage.quoted_table_name}.created_at)"
      @message_times = scope
                         .where("#{time_expr} >= ? AND #{time_expr} < ?", @from_t, @to_t)
                         .pluck(Arel.sql(time_expr))
                         .compact
    end

    # --- Buckets (Implementierung in StatisticsSupport) ----------------------

    # Klassenmethoden bleiben als Delegates erhalten (Tests, AiUsageStatistics).
    def self.bucket_key(time, period)
      StatisticsSupport.bucket_key(time, period)
    end

    # --- Ausgabe-Helfer ------------------------------------------------------

    # Reaktion endet spaetestens beim Schliessen: ohne erfasste Erstreaktion gilt
    # bei geschlossenen Tickets der Schliesszeitpunkt als Abschluss.
    def reaction_status(r)
      done = r.first_response_at || r.closed_on
      Sla.clock_status_from(r.reaction_due_at, r.reaction_warn_at, done)
    end

    def solution_status(r)
      Sla.clock_status_from(r.solution_due_at, r.solution_warn_at, r.closed_on)
    end

    def self.mean(arr)
      StatisticsSupport.mean(arr)
    end

    def self.median(arr)
      StatisticsSupport.median(arr)
    end
  end
end
