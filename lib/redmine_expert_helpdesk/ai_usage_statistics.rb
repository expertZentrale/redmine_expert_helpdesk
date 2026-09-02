# Aggregiert Kennzahlen fuer die KI-Statistik-Seite eines Projekts.
#
# Basis: das Nutzungs-Protokoll (HelpdeskAiRequest) – jeder KI-Aufruf
# (Zusammenfassung, KB-Extraktion, Embedding, RAG-Retrieval) mit Provider/Modell,
# Token, Dauer und Erfolg/Fehler. Gruppierung nach Tag/Woche/Monat/Jahr; Zeit-
# Buckets/"Stosszeiten" in lokaler Serverzeit (konsistent mit SlaStatistics).
#
# Liefert reine Ruby-Datenstrukturen (to_h) ohne Rendering-Logik, damit die
# Aggregation isoliert testbar bleibt. Bucketing/Mittelwerte werden aus
# SlaStatistics wiederverwendet.
module RedmineExpertHelpdesk
  class AiUsageStatistics
    PERIODS = SlaStatistics::PERIODS

    Row = Struct.new(:id, :request_type, :provider, :model,
                     :input_tokens, :output_tokens, :duration_ms, :success, :error_class, :created_at)

    def initialize(project, period: 'month', date_from: nil, date_to: nil)
      @project = project
      @period  = PERIODS.include?(period.to_s) ? period.to_s : 'month'
      @date_to   = date_to   || Date.current
      @date_from = date_from || (@date_to - 30)
      @date_from, @date_to = @date_to, @date_from if @date_from > @date_to

      @from_t = @date_from.to_time         # lokale Mitternacht (Start inkl.)
      @to_t   = (@date_to + 1).to_time     # lokale Mitternacht Folgetag (Ende exkl.)
    end

    def to_h
      rows = load_rows
      {
        :period    => @period,
        :date_from => @date_from,
        :date_to   => @date_to,
        :totals    => totals(rows),
        :by_type   => by_type(rows),
        :by_model  => by_model(rows),
        :volume    => volume_series(rows),
        :errors    => errors(rows),
        :busiest_hours    => busiest_hours(rows),
        :busiest_weekdays => busiest_weekdays(rows),
        :kb        => kb_counts
      }
    end

    private

    def load_rows
      HelpdeskAiRequest
        .where(:project_id => @project.id)
        .where("created_at >= ? AND created_at < ?", @from_t, @to_t)
        .pluck(:id, :request_type, :provider, :model,
               :input_tokens, :output_tokens, :duration_ms, :success, :error_class, :created_at)
        .map { |r| Row.new(*r) }
    end

    def totals(rows)
      success = rows.count(&:success)
      failed  = rows.size - success
      input   = rows.sum { |r| r.input_tokens.to_i }
      output  = rows.sum { |r| r.output_tokens.to_i }
      durations = rows.select(&:success).filter_map(&:duration_ms)
      {
        :requests      => rows.size,
        :success       => success,
        :failed        => failed,
        :success_ratio => rows.any? ? (success * 100.0 / rows.size).round(1) : nil,
        :input_tokens  => input,
        :output_tokens => output,
        :total_tokens  => input + output,
        :avg_latency_ms => SlaStatistics.mean(durations),
        :p95_latency_ms => percentile(durations, 95),
        :summaries     => rows.count { |r| r.request_type == 'summary' },
        # Explicit prefix match: "everything that is not a summary" used to be the
        # KB counter, which would now silently absorb the completeness checks too.
        :kb_requests   => rows.count { |r| r.request_type.to_s.start_with?('kb_') }
      }
    end

    # Aufschluesselung je Anfragetyp (feste Reihenfolge, nur vorhandene Typen).
    def by_type(rows)
      grouped = rows.group_by(&:request_type)
      HelpdeskAiRequest::REQUEST_TYPES.filter_map do |type|
        rs = grouped[type]
        next unless rs
        { :type => type, :requests => rs.size,
          :tokens => rs.sum { |r| r.input_tokens.to_i + r.output_tokens.to_i },
          :failed => rs.count { |r| !r.success } }
      end
    end

    # Aufschluesselung je Provider/Modell, absteigend nach Anzahl.
    def by_model(rows)
      rows.group_by { |r| [r.provider, r.model] }.map do |(provider, model), rs|
        { :provider => provider, :model => model,
          :label    => [provider, model].reject { |v| v.to_s.empty? }.join(' · ').presence || '–',
          :requests => rs.size,
          :tokens   => rs.sum { |r| r.input_tokens.to_i + r.output_tokens.to_i } }
      end.sort_by { |h| -h[:requests] }
    end

    # Anzahl/Token je Bucket inkl. leerer Buckets, damit die Balken luecklos sind.
    def volume_series(rows)
      requests = Hash.new(0)
      input    = Hash.new(0)
      output   = Hash.new(0)
      failed   = Hash.new(0)
      rows.each do |r|
        key = bucket_key(r.created_at)
        requests[key] += 1
        input[key]    += r.input_tokens.to_i
        output[key]   += r.output_tokens.to_i
        failed[key]   += 1 unless r.success
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label, :requests => requests[key],
          :input_tokens => input[key], :output_tokens => output[key], :failed => failed[key] }
      end
    end

    # Fehler nach Fehlerklasse, absteigend.
    def errors(rows)
      rows.reject(&:success).group_by { |r| r.error_class.presence || '–' }
          .map { |cls, rs| { :error_class => cls, :count => rs.size } }
          .sort_by { |h| -h[:count] }
    end

    def busiest_hours(rows)
      counts = Array.new(24, 0)
      rows.each { |r| counts[local(r.created_at).hour] += 1 }
      counts
    end

    # ISO-Wochentage 1=Mo .. 7=So.
    def busiest_weekdays(rows)
      counts = Array.new(7, 0)
      rows.each { |r| counts[((local(r.created_at).wday + 6) % 7)] += 1 }
      counts
    end

    # Zustaende der Wissensbasis-Eintraege des Projekts im Zeitraum.
    def kb_counts(*)
      base = { 'pending' => 0, 'approved' => 0, 'skipped' => 0 }
      counts = HelpdeskKnowledgeEntry
                 .where(:project_id => @project.id)
                 .where("created_at >= ? AND created_at < ?", @from_t, @to_t)
                 .group(:status).count
      base.merge(counts).transform_keys(&:to_sym)
    end

    # --- Buckets (wie SlaStatistics) ----------------------------------------

    def local(time)
      time.respond_to?(:getlocal) ? time.getlocal : time.to_time
    end

    def bucket_key(time)
      SlaStatistics.bucket_key(time, @period)
    end

    def bucket_label(key)
      @period == 'month' ? Date.strptime(key, '%Y-%m').strftime('%m/%Y') : key
    end

    def ordered_buckets
      return @ordered_buckets if defined?(@ordered_buckets)

      seen = {}
      date = @date_from
      while date <= @date_to
        key = bucket_key(date.to_time)
        seen[key] ||= bucket_label(key)
        date += 1
      end
      @ordered_buckets = seen.to_a
    end

    # Lineare Interpolation (0..100). nil bei leerer Eingabe.
    def percentile(arr, pct)
      return nil if arr.empty?

      sorted = arr.sort
      rank   = pct / 100.0 * (sorted.size - 1)
      lower  = sorted[rank.floor]
      upper  = sorted[rank.ceil]
      (lower + (upper - lower) * (rank - rank.floor)).round
    end
  end
end
