# Aggregates the figures of the per-project "Ticket statistics" page: how the
# team works its helpdesk tickets, independent of SLA.
#
# Scope: issues of ONE project (no subprojects) that have a helpdesk_ticket_infos
# row ("helpdesk tickets") and were created in the selected period. Unlike
# SlaStatistics there is no sla_enabled_at cut-off.
#
# Durations are integer minutes, wall clock by default. With business_hours: true
# (only honoured when the project's SLA is enabled) they are business minutes of
# the project's working hours; stored SLA minutes are reused where present.
# BusinessHours#elapsed_minutes is an O(days) loop per interval; realistic
# ranges stay well below a second, a per-date cache would be the next step if a
# five-year range on a huge project ever hurts.
#
# Definitions that matter for reading the numbers:
# - closed: the CURRENT status is flagged is_closed. Redmine keeps issues.closed_on
#   after a reopen, so closed_on alone would count reopened tickets as closed.
# - reopen: a status transition from a closed to a non-closed status (today's
#   is_closed flags; history is not reconstructed if statuses were reflagged).
# - agent reply: a public, non-empty journal note by a real user that is not the
#   MailHandler journal of an incoming mail and, on customer-created tickets, not
#   by the ticket author.
# - incoming / agent / automated mail: see classify_message.
# - time in status: COMPLETED segments only (a transition out happened), built
#   from journal_details status changes; the plugin journals its own mail reopens
#   so this history is complete. Open tickets additionally count as "currently in".
# - assigned: the current assignee (a User or a Group); reassignments are invisible.
#
# Busiest hours/weekdays count incoming mails of in-scope tickets that arrived in
# the period (SlaStatistics counts in-range mails of older tickets too).
#
# Pure Ruby output (to_h), no rendering. The per-ticket fold (ticket_metrics) and
# every table builder are class methods without DB access so they stay testable.
module RedmineExpertHelpdesk
  class TicketStatistics
    include StatisticsSupport

    PERIODS       = StatisticsSupport::PERIODS
    TOP_CUSTOMERS = 20

    # Incoming mails per ticket -> bucket key.
    CONVERSATION_BUCKETS = [
      ['0', 0..0], ['1', 1..1], ['2', 2..2], ['3-5', 3..5], ['6-10', 6..10], ['>10', 11..]
    ].freeze

    TicketRow  = Struct.new(:id, :created_on, :closed_on, :status_id, :assigned_to_id, :author_id,
                            :first_response_at, :reaction_minutes, :solution_minutes,
                            :awaiting_agent_since, :contact_id)
    MessageRow = Struct.new(:issue_id, :direction, :journal_id, :message_id, :at)
    JournalRow = Struct.new(:id, :issue_id, :user_id, :created_on, :private_notes, :has_notes,
                            :detail_id, :old_status_id, :new_status_id)
    # segments = [[status_id, from, to]] (completed only)
    Timeline   = Struct.new(:initial_status_id, :segments, :current_status_id, :current_since)
    TicketMetrics = Struct.new(:id, :created_on, :closed, :closed_on, :assigned_to_id, :contact_id,
                               :awaiting, :first_response_minutes, :resolution_minutes,
                               :incoming, :agent_replies, :automated, :customer_created,
                               :first_reply_user_id, :reply_user_ids, :closed_by_user_id,
                               :reopen_count, :timeline, :segment_minutes)

    def initialize(project, period: 'month', date_from: nil, date_to: nil, business_hours: false)
      @project = project
      @period  = StatisticsSupport.normalize_period(period)
      @date_to   = date_to   || Date.current
      @date_from = date_from || (@date_to - 30)
      @date_from, @date_to = @date_to, @date_from if @date_from > @date_to

      @setting = HelpdeskProjectSetting.for_project(project)
      @business_hours = business_hours && @setting.persisted? && @setting.sla_enabled?
      @from_t = @date_from.to_time         # local midnight (start, inclusive)
      @to_t   = (@date_to + 1).to_time     # local midnight of the next day (end, exclusive)
    end

    def business_hours?
      @business_hours
    end

    def to_h
      metrics = build_metrics
      {
        :period         => @period,
        :date_from      => @date_from,
        :date_to        => @date_to,
        :business_hours => @business_hours,
        :totals         => self.class.totals(metrics),
        :volume         => volume_series(metrics),
        :avg_trend      => average_trend(metrics),
        :statuses       => self.class.status_table(metrics, statuses),
        :agents         => resolve_principals(self.class.agent_table(metrics)),
        :customers      => resolve_contacts(self.class.customer_table(metrics, :limit => TOP_CUSTOMERS)),
        :conversation   => self.class.conversation(metrics),
        :busiest_hours    => StatisticsSupport.hour_histogram(@incoming_times.to_a),
        :busiest_weekdays => StatisticsSupport.weekday_histogram(@incoming_times.to_a)
      }
    end

    # --- Pure per-ticket / table logic (no DB) ------------------------------

    # :incoming (customer mail), :agent (mail an agent sent: reply or initial
    # mail), :automated (autoresponder / follow-up: outbound without journal and
    # without Message-ID), nil for 'init' rows (contact linked, nothing sent).
    def self.classify_message(direction, journal_id, message_id)
      case direction
      when 'in'  then :incoming
      when 'out' then (journal_id || message_id) ? :agent : :automated
      end
    end

    # transitions = [[at, old_status_id, new_status_id, ...]] sorted by time.
    # Segment i covers [previous transition (or created_on), transition i] in the
    # status the transition left - old_value is trusted per transition, so a gap
    # in the history does not shift every later segment.
    def self.status_timeline(created_on, current_status_id, transitions)
      return Timeline.new(current_status_id, [], current_status_id, created_on) if transitions.empty?

      segments = []
      prev_at  = created_on
      transitions.each do |at, old_id, _new_id, *|
        segments << [old_id, prev_at, at]
        prev_at = at
      end
      Timeline.new(transitions.first[1], segments, current_status_id, prev_at)
    end

    def self.reopen_count(transitions, closed_ids)
      transitions.count { |_at, old_id, new_id, *| closed_ids.include?(old_id) && !closed_ids.include?(new_id) }
    end

    def self.agent_reply?(journal, anonymous_id:, incoming_journal_ids:, author_id:, customer_created:)
      return false unless journal.has_notes && !journal.private_notes
      return false if journal.user_id.nil? || journal.user_id == anonymous_id
      return false if incoming_journal_ids.include?(journal.id)
      return false if customer_created && journal.user_id == author_id

      true
    end

    def self.conversation_bucket(incoming)
      CONVERSATION_BUCKETS.find { |_key, range| range.cover?(incoming) }&.first
    end

    # Folds one ticket with its journals (JournalRow, sorted) and messages
    # (MessageRow) into a TicketMetrics. `duration` is a lambda (from, to) ->
    # minutes or nil (nil when either is missing or to < from), wall clock or
    # business hours; keeping it injected keeps this method pure.
    def self.ticket_metrics(ticket, journals, messages, closed_ids:, anonymous_id:, duration:, business_hours: false)
      closed    = closed_ids.include?(ticket.status_id)
      closed_on = closed ? ticket.closed_on : nil

      kinds = messages.map { |m| classify_message(m.direction, m.journal_id, m.message_id) }
      first_message = messages.reject { |m| m.at.nil? }.min_by(&:at)
      agent_created = messages.any? { |m| m.direction == 'init' } ||
                      (first_message && classify_message(first_message.direction, first_message.journal_id,
                                                         first_message.message_id) == :agent)
      incoming_journal_ids = messages.select { |m| m.direction == 'in' && m.journal_id }.map(&:journal_id).to_set

      transitions = journals.select(&:detail_id).reject { |j| j.old_status_id.nil? }
                            .map { |j| [j.created_on, j.old_status_id, j.new_status_id, j.user_id] }
      replies = journals.uniq(&:id).select do |j|
        agent_reply?(j, :anonymous_id => anonymous_id, :incoming_journal_ids => incoming_journal_ids,
                        :author_id => ticket.author_id, :customer_created => !agent_created)
      end

      first_response = if business_hours && ticket.reaction_minutes
                         ticket.reaction_minutes
                       elsif ticket.first_response_at
                         duration.call(ticket.created_on, ticket.first_response_at)
                       end
      resolution = if closed_on.nil?
                     nil
                   elsif business_hours && ticket.solution_minutes
                     ticket.solution_minutes
                   else
                     duration.call(ticket.created_on, closed_on)
                   end

      closing = transitions.reverse.find { |_at, _old, new_id, _user| closed_ids.include?(new_id) }
      closed_by = closing && closing[3]
      closed_by = nil if closed_by == anonymous_id

      timeline = status_timeline(ticket.created_on, ticket.status_id, transitions)
      segment_minutes = timeline.segments.map { |sid, from, to| [sid, duration.call(from, to) || 0] }

      TicketMetrics.new(
        ticket.id, ticket.created_on, closed, closed_on, ticket.assigned_to_id, ticket.contact_id,
        !ticket.awaiting_agent_since.nil?, first_response, resolution,
        kinds.count(:incoming), replies.size, kinds.count(:automated), !agent_created,
        replies.first&.user_id, replies.map(&:user_id), closed_by,
        reopen_count(transitions, closed_ids), timeline, segment_minutes
      )
    end

    def self.totals(metrics)
      closed = metrics.select(&:closed)
      first  = metrics.filter_map(&:first_response_minutes)
      resol  = metrics.filter_map(&:resolution_minutes)
      one_touch = closed.count { |m| m.agent_replies <= 1 }
      {
        :tickets           => metrics.size,
        :open              => metrics.size - closed.size,
        :closed            => closed.size,
        :reopened_tickets  => metrics.count { |m| m.reopen_count > 0 },
        :reopen_count      => metrics.sum(&:reopen_count),
        :awaiting_agent    => metrics.count { |m| !m.closed && m.awaiting },
        :first_response_mean   => StatisticsSupport.mean(first),
        :first_response_median => StatisticsSupport.median(first),
        :first_response_count  => first.size,
        :resolution_mean   => StatisticsSupport.mean(resol),
        :resolution_median => StatisticsSupport.median(resol),
        :resolution_count  => resol.size,
        :one_touch         => one_touch,
        :one_touch_ratio   => closed.any? ? (one_touch * 100.0 / closed.size).round(1) : nil,
        :automated_mails   => metrics.sum(&:automated)
      }
    end

    # statuses = [[id, name, closed?]] in display order. Only statuses that occur
    # in the tickets' histories are returned; unknown ids (deleted statuses in old
    # journals) get a nil name.
    def self.status_table(metrics, statuses)
      seen = Hash.new { |h, k| h[k] = { :initial => 0, :tickets => 0, :current => 0, :dwell => [] } }
      metrics.each do |m|
        tl = m.timeline
        ids = ([tl.initial_status_id, tl.current_status_id] + tl.segments.map(&:first)).compact.uniq
        ids.each { |sid| seen[sid][:tickets] += 1 }
        seen[tl.initial_status_id][:initial] += 1 if tl.initial_status_id
        seen[tl.current_status_id][:current] += 1 if tl.current_status_id
        m.segment_minutes.each { |sid, minutes| seen[sid][:dwell] << minutes }
      end
      known = statuses.map(&:first)
      order = known + (seen.keys - known)
      order.filter_map do |sid|
        s = seen[sid] if seen.key?(sid)
        next unless s

        _id, name, closed = statuses.find { |st| st.first == sid }
        { :id => sid, :name => name, :closed => closed ? true : false,
          :initial => s[:initial], :tickets => s[:tickets], :current => s[:current],
          :dwell_count  => s[:dwell].size,
          :dwell_mean   => StatisticsSupport.mean(s[:dwell]),
          :dwell_median => StatisticsSupport.median(s[:dwell]) }
      end
    end

    # Rows keyed by principal id (nil = unassigned, always last). Assigned/open/
    # closed/resolution follow the current assignee, replies and closed_by the
    # journal user (closed_by only when a status journal names one), first
    # response the user of the first agent reply.
    def self.agent_table(metrics)
      rows = Hash.new do |h, k|
        h[k] = { :principal_id => k, :assigned => 0, :open => 0, :closed => 0, :replies => 0,
                 :closed_by => 0, :first_response => [], :resolution => [] }
      end
      metrics.each do |m|
        row = rows[m.assigned_to_id]
        row[:assigned] += 1
        row[m.closed ? :closed : :open] += 1
        row[:resolution] << m.resolution_minutes if m.resolution_minutes
        m.reply_user_ids.each { |uid| rows[uid][:replies] += 1 }
        # Closures are attributed only when a journal names the user; a close by
        # anonymous (mail keyword) or without status history stays unattributed.
        rows[m.closed_by_user_id][:closed_by] += 1 if m.closed_by_user_id
        if m.first_response_minutes && m.first_reply_user_id
          rows[m.first_reply_user_id][:first_response] << m.first_response_minutes
        end
      end
      finished = rows.values.map do |r|
        { :principal_id => r[:principal_id], :assigned => r[:assigned], :open => r[:open],
          :closed => r[:closed], :replies => r[:replies], :closed_by => r[:closed_by],
          :first_response_median => StatisticsSupport.median(r[:first_response]),
          :first_response_count  => r[:first_response].size,
          :resolution_median     => StatisticsSupport.median(r[:resolution]),
          :resolution_count      => r[:resolution].size }
      end
      named, unassigned = finished.partition { |r| r[:principal_id] }
      named.sort_by { |r| [-r[:assigned], -r[:replies], r[:principal_id]] } + unassigned
    end

    # Top `limit` contacts by ticket count; the "no contact" bucket (nil) is
    # appended last and only when it is non-empty.
    def self.customer_table(metrics, limit: TOP_CUSTOMERS)
      rows = Hash.new do |h, k|
        h[k] = { :contact_id => k, :tickets => 0, :open => 0, :closed => 0, :incoming => 0,
                 :replies => 0, :resolution => [] }
      end
      metrics.each do |m|
        row = rows[m.contact_id]
        row[:tickets] += 1
        row[m.closed ? :closed : :open] += 1
        row[:incoming] += m.incoming
        row[:replies]  += m.agent_replies
        row[:resolution] << m.resolution_minutes if m.resolution_minutes
      end
      finished = rows.values.map do |r|
        { :contact_id => r[:contact_id], :tickets => r[:tickets], :open => r[:open],
          :closed => r[:closed], :incoming => r[:incoming], :replies => r[:replies],
          :resolution_median => StatisticsSupport.median(r[:resolution]),
          :resolution_count  => r[:resolution].size }
      end
      named, none = finished.partition { |r| r[:contact_id] }
      named.sort_by { |r| [-r[:tickets], -r[:incoming], r[:contact_id]] }.first(limit) + none
    end

    def self.conversation(metrics)
      counts = Hash.new(0)
      metrics.each { |m| counts[conversation_bucket(m.incoming)] += 1 }
      closed = metrics.select(&:closed)
      one_touch = closed.count { |m| m.agent_replies <= 1 }
      incoming = metrics.map(&:incoming)
      replies  = metrics.map(&:agent_replies)
      {
        :buckets => CONVERSATION_BUCKETS.map { |key, _r| { :key => key, :tickets => counts[key] } },
        :incoming_mean   => StatisticsSupport.mean(incoming),
        :incoming_median => StatisticsSupport.median(incoming),
        :replies_mean    => StatisticsSupport.mean(replies),
        :replies_median  => StatisticsSupport.median(replies),
        :automated_total => metrics.sum(&:automated),
        :one_touch       => one_touch,
        :one_touch_ratio => closed.any? ? (one_touch * 100.0 / closed.size).round(1) : nil
      }
    end

    private

    # --- Loading -----------------------------------------------------------

    def issues_t
      Issue.quoted_table_name
    end

    def ti_join
      "INNER JOIN helpdesk_ticket_infos ti ON ti.issue_id = #{issues_t}.id"
    end

    # Helpdesk tickets of the project created in the period.
    def in_scope
      "#{issues_t}.project_id = ? AND #{issues_t}.created_on >= ? AND #{issues_t}.created_on < ?"
    end

    def scope_args
      [@project.id, @from_t, @to_t]
    end

    def statuses
      @statuses ||= IssueStatus.order(:position).pluck(:id, :name, :is_closed)
    end

    def closed_ids
      @closed_ids ||= statuses.select { |_id, _name, closed| closed }.map(&:first).to_set
    end

    def load_tickets
      Issue.joins(ti_join)
           .where(in_scope, *scope_args)
           .pluck("#{issues_t}.id", "#{issues_t}.created_on", "#{issues_t}.closed_on",
                  "#{issues_t}.status_id", "#{issues_t}.assigned_to_id", "#{issues_t}.author_id",
                  'ti.first_response_at', 'ti.reaction_business_minutes', 'ti.solution_business_minutes',
                  'ti.awaiting_agent_since',
                  Arel.sql(RedmineExpertHelpdesk::Patches::IssueQueryPatch::HELPDESK_CUSTOMER_CONTACT_ID_SQL))
           .map { |r| TicketRow.new(*r) }
    end

    # All messages of in-scope tickets (any time), grouped by issue id.
    def load_messages
      hm = HelpdeskMessage.quoted_table_name
      time_expr = "COALESCE(#{hm}.sent_at, #{hm}.created_at)"
      HelpdeskMessage
        .joins("INNER JOIN #{issues_t} ON #{issues_t}.id = #{hm}.issue_id")
        .joins(ti_join)
        .where(in_scope, *scope_args)
        .pluck("#{hm}.issue_id", "#{hm}.direction", "#{hm}.journal_id", "#{hm}.message_id", Arel.sql(time_expr))
        .map { |r| MessageRow.new(*r) }
        .group_by(&:issue_id)
    end

    # Journals with a note and/or a status change, one row per (journal, status
    # detail), sorted by ticket and time. A journal with two status details (the
    # plugin appends a reopen detail to MailHandler's journal) yields two rows.
    def load_journals
      j  = Journal.quoted_table_name
      jd = JournalDetail.quoted_table_name
      has_notes = "COALESCE(#{j}.notes, '') <> ''"
      Journal
        .joins("INNER JOIN #{issues_t} ON #{issues_t}.id = #{j}.journalized_id AND #{j}.journalized_type = 'Issue'")
        .joins(ti_join)
        .joins("LEFT JOIN #{jd} ON #{jd}.journal_id = #{j}.id AND #{jd}.property = 'attr' AND #{jd}.prop_key = 'status_id'")
        .where(in_scope, *scope_args)
        .where("#{has_notes} OR #{jd}.id IS NOT NULL")
        .order(Arel.sql("#{j}.journalized_id, #{j}.created_on, #{j}.id, #{jd}.id"))
        .pluck("#{j}.id", "#{j}.journalized_id", "#{j}.user_id", "#{j}.created_on", "#{j}.private_notes",
               Arel.sql("CASE WHEN #{has_notes} THEN 1 ELSE 0 END"),
               "#{jd}.id", "#{jd}.old_value", "#{jd}.value")
        .map do |id, issue_id, user_id, created_on, private_notes, has_note, detail_id, old_v, new_v|
          JournalRow.new(id, issue_id, user_id, created_on, private_notes ? true : false, has_note.to_i == 1,
                         detail_id, detail_id && old_v.presence && old_v.to_i, detail_id && new_v.presence && new_v.to_i)
        end
        .group_by(&:issue_id)
    end

    def build_metrics
      @incoming_times = []
      tickets = load_tickets
      return [] if tickets.empty?

      messages = load_messages
      journals = load_journals
      anonymous_id = User.anonymous.id
      dur = duration_fn

      messages.each_value do |ms|
        ms.each do |m|
          next unless m.direction == 'in' && m.at
          @incoming_times << m.at if m.at >= @from_t && m.at < @to_t
        end
      end

      tickets.map do |t|
        self.class.ticket_metrics(t, journals[t.id] || [], messages[t.id] || [],
                                  :closed_ids => closed_ids, :anonymous_id => anonymous_id,
                                  :duration => dur, :business_hours => @business_hours)
      end
    end

    def duration_fn
      if @business_hours
        bh = BusinessHours.new(@setting)
        ->(from, to) { from && to && to >= from ? bh.elapsed_minutes(from, to) : nil }
      else
        ->(from, to) { from && to && to >= from ? ((to - from) / 60.0).round : nil }
      end
    end

    # --- Series --------------------------------------------------------------

    def volume_series(metrics)
      created = Hash.new(0)
      closed  = Hash.new(0)
      metrics.each do |m|
        created[bucket_key(m.created_on)] += 1
        closed[bucket_key(m.closed_on)] += 1 if m.closed_on && m.closed_on >= @from_t && m.closed_on < @to_t
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label, :created => created[key], :closed => closed[key] }
      end
    end

    def average_trend(metrics)
      first = Hash.new { |h, k| h[k] = [] }
      resol = Hash.new { |h, k| h[k] = [] }
      metrics.each do |m|
        key = bucket_key(m.created_on)
        first[key] << m.first_response_minutes if m.first_response_minutes
        resol[key] << m.resolution_minutes if m.resolution_minutes
      end
      ordered_buckets.map do |key, label|
        { :key => key, :label => label,
          :first_response => mean(first[key]), :first_response_count => first[key].size,
          :resolution => mean(resol[key]), :resolution_count => resol[key].size }
      end
    end

    # --- Name resolution -----------------------------------------------------

    def resolve_principals(rows)
      ids = rows.filter_map { |r| r[:principal_id] }
      principals = ids.empty? ? {} : Principal.where(:id => ids).index_by(&:id)
      rows.map do |r|
        p = r[:principal_id] && principals[r[:principal_id]]
        r.merge(:name => p&.name, :type => p && (p.is_a?(Group) ? 'Group' : 'User'),
                :deleted => !r[:principal_id].nil? && p.nil?)
      end
    end

    def resolve_contacts(rows)
      ids = rows.filter_map { |r| r[:contact_id] }
      contacts = ids.empty? ? {} : HelpdeskContact.where(:id => ids).pluck(:id, :name, :company, :email)
                                                   .each_with_object({}) { |(id, *rest), h| h[id] = rest }
      rows.map do |r|
        name, company, email = contacts[r[:contact_id]]
        r.merge(:name => name, :company => company, :email => email,
                :deleted => !r[:contact_id].nil? && !contacts.key?(r[:contact_id]))
      end
    end
  end
end
