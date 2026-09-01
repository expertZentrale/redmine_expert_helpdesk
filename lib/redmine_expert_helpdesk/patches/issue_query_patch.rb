# Extends IssueQuery with:
# - columns "Kunde" and "Kunden-E-Mail" (sortable via subquery on
#   helpdesk_contacts)
# - filter "Kunde" (text search on name or email address)
# - columns/filters "SLA reaction" and "SLA solution": status per SLA clock,
#   from the precomputed deadlines (helpdesk_ticket_infos) by plain timestamp
#   comparison against UTC_TIMESTAMP() (MariaDB; AR stores datetimes as UTC).
#
# Uses prepend so initialize_available_filters can call super (include sits
# below the class in the ancestor chain, so it could not override the method
# IssueQuery defines itself).
module RedmineExpertHelpdesk
  module Patches
    module IssueQueryPatch
      # SQL mirror of Issue#helpdesk_customer_contact: the authoritative
      # helpdesk_ticket_infos link first, then the sender of the first
      # incoming mail WITH a contact. Both subqueries JOIN helpdesk_contacts
      # so only existing contacts participate in the COALESCE -- a NULL or
      # dangling helpdesk_contact_id falls through to the fallback exactly
      # like the Ruby resolver (nil association resp. joins(:helpdesk_contact)).
      # Shared by the customer sort SQLs and the filter.
      HELPDESK_CUSTOMER_CONTACT_ID_SQL =
        "COALESCE(" \
        "(SELECT hc.id FROM helpdesk_contacts hc" \
        " INNER JOIN helpdesk_ticket_infos ti ON ti.helpdesk_contact_id = hc.id" \
        " WHERE ti.issue_id = #{Issue.quoted_table_name}.id)," \
        " (SELECT hc.id FROM helpdesk_contacts hc" \
        " INNER JOIN helpdesk_messages hm ON hm.helpdesk_contact_id = hc.id" \
        " WHERE hm.issue_id = #{Issue.quoted_table_name}.id AND hm.direction = 'in'" \
        " ORDER BY hm.id ASC LIMIT 1))".freeze

      HELPDESK_KUNDE_SORT_SQL =
        "(SELECT COALESCE(hc.name, hc.email) FROM helpdesk_contacts hc" \
        " WHERE hc.id = #{HELPDESK_CUSTOMER_CONTACT_ID_SQL})".freeze

      HELPDESK_KUNDE_EMAIL_SORT_SQL =
        "(SELECT hc.email FROM helpdesk_contacts hc" \
        " WHERE hc.id = #{HELPDESK_CUSTOMER_CONTACT_ID_SQL})".freeze

      # Schweregrad-Rang je Uhr (0 kein SLA .. 5 ueberschritten). done_at ist bei
      # der Reaktion first_response_at, bei der Loesung issues.closed_on.
      def self.sla_rank_sql(done_at_expr, due_col, warn_col)
        <<~SQL.squish.freeze
          (SELECT CASE
             WHEN ti.#{due_col} IS NULL THEN 0
             WHEN #{done_at_expr} IS NOT NULL
               THEN (CASE WHEN #{done_at_expr} <= ti.#{due_col} THEN 1 ELSE 4 END)
             WHEN UTC_TIMESTAMP() > ti.#{due_col} THEN 5
             WHEN ti.#{warn_col} IS NOT NULL AND UTC_TIMESTAMP() >= ti.#{warn_col} THEN 3
             ELSE 2 END
           FROM helpdesk_ticket_infos ti WHERE ti.issue_id = #{Issue.quoted_table_name}.id)
        SQL
      end

      # Reaktion: ohne erfasste Erstreaktion gilt der Schliesszeitpunkt als
      # Abschluss (Reaktionsuhr laeuft nicht ueber das Loesen hinaus weiter).
      SLA_REACTION_RANK_SQL =
        sla_rank_sql("COALESCE(ti.first_response_at, #{Issue.quoted_table_name}.closed_on)",
                     'sla_reaction_due_at', 'sla_reaction_warn_at')
      SLA_SOLUTION_RANK_SQL =
        sla_rank_sql("#{Issue.quoted_table_name}.closed_on", 'sla_solution_due_at', 'sla_solution_warn_at')

      # Filter-Status -> Rang (muss zur CASE-Logik oben passen).
      SLA_STATUS_RANKS = {
        'met'           => 1,
        'running'       => 2,
        'warning'       => 3,
        'breached_done' => 4,
        'breached'      => 5
      }.freeze

      # "Wartet auf Bearbeitung": Zeitpunkt der aeltesten unbeantworteten Kunden-
      # antwort. Anders als bei den SLA-Spalten ist das ein reiner IS-NULL-Test,
      # daher kein UTC_TIMESTAMP() und kein Zeitzonen-Thema; das Wartealter wird in
      # Ruby gerendert.
      AWAITING_SINCE_SQL = <<~SQL.squish.freeze
        (SELECT ti.awaiting_agent_since FROM helpdesk_ticket_infos ti
         WHERE ti.issue_id = #{Issue.quoted_table_name}.id)
      SQL

      # Aufsteigend sortiert: wartende Tickets zuerst, darin die am laengsten
      # wartenden zuerst. Wartende bekommen daher 0, nicht 1.
      AWAITING_SORT_SQL = [
        "(CASE WHEN #{AWAITING_SINCE_SQL} IS NULL THEN 1 ELSE 0 END)",
        AWAITING_SINCE_SQL
      ].freeze

      def self.prepended(base)
        unless base.available_columns.any? { |c| c.name == :helpdesk_kunde }
          base.available_columns << QueryColumn.new(
            :helpdesk_kunde,
            :sortable => HELPDESK_KUNDE_SORT_SQL,
            :caption  => :label_helpdesk_customer
          )
        end

        # Email-only sibling of "Kunde": display names can be long and unclear.
        # Plain text on purpose (no mailto -- accidental clicks in dense lists).
        unless base.available_columns.any? { |c| c.name == :helpdesk_kunde_email }
          base.available_columns << QueryColumn.new(
            :helpdesk_kunde_email,
            :sortable => HELPDESK_KUNDE_EMAIL_SORT_SQL,
            :caption  => :label_helpdesk_customer_email
          )
        end

        unless base.available_columns.any? { |c| c.name == :helpdesk_sla_reaction }
          base.available_columns << QueryColumn.new(
            :helpdesk_sla_reaction,
            :sortable => SLA_REACTION_RANK_SQL,
            :caption  => :label_helpdesk_sla_reaction_col
          )
        end

        unless base.available_columns.any? { |c| c.name == :helpdesk_sla_solution }
          base.available_columns << QueryColumn.new(
            :helpdesk_sla_solution,
            :sortable => SLA_SOLUTION_RANK_SQL,
            :caption  => :label_helpdesk_sla_solution_col
          )
        end

        # Bewusst nicht an einen Setting-Lesezugriff gekoppelt: prepended laeuft beim
        # Boot, ein Setting-Zugriff dort waere ein Boot-Order-Risiko. Eine registrierte,
        # ggf. leere Spalte ist harmlos.
        unless base.available_columns.any? { |c| c.name == :helpdesk_awaiting_agent }
          base.available_columns << QueryColumn.new(
            :helpdesk_awaiting_agent,
            :sortable => AWAITING_SORT_SQL,
            :caption  => :label_helpdesk_awaiting_agent_col
          )
        end
      end

      # Filter-Definition: wird bei jeder Query-Instanz registriert
      def initialize_available_filters
        super
        add_available_filter 'helpdesk_kunde',
          :type  => :text,
          :label => :label_helpdesk_customer

        sla_filter_values = SLA_STATUS_RANKS.keys.map { |k| [l("label_helpdesk_sla_#{k}"), k] }
        add_available_filter 'helpdesk_sla_reaction',
          :type => :list, :label => :label_helpdesk_sla_reaction_col, :values => sla_filter_values
        add_available_filter 'helpdesk_sla_solution',
          :type => :list, :label => :label_helpdesk_sla_solution_col, :values => sla_filter_values

        add_available_filter 'helpdesk_awaiting_agent',
          :type => :list, :label => :label_helpdesk_awaiting_agent_col,
          :values => [[l(:label_helpdesk_awaiting_yes), '1'], [l(:label_helpdesk_awaiting_no), '0']]
      end

      def sql_for_helpdesk_sla_reaction_field(field, operator, value)
        sla_rank_condition(SLA_REACTION_RANK_SQL, operator, value)
      end

      def sql_for_helpdesk_sla_solution_field(field, operator, value)
        sla_rank_condition(SLA_SOLUTION_RANK_SQL, operator, value)
      end

      def sql_for_helpdesk_awaiting_agent_field(field, operator, value)
        exists = <<~SQL.squish
          EXISTS (SELECT 1 FROM helpdesk_ticket_infos ti
                  WHERE ti.issue_id = #{Issue.quoted_table_name}.id
                    AND ti.awaiting_agent_since IS NOT NULL)
        SQL

        values = Array(value)
        cond = if values.include?('1') && values.include?('0')
                 '1=1'
               elsif values.include?('1')
                 exists
               elsif values.include?('0')
                 "NOT (#{exists})"
               else
                 '1=0'
               end

        operator == '!' ? "NOT (#{cond})" : cond
      end

      # Baut die Bedingung "(rang) IN (...)" fuer den Listen-Filter.
      def sla_rank_condition(rank_sql, operator, value)
        ranks = Array(value).map { |v| SLA_STATUS_RANKS[v] }.compact
        return '1=0' if ranks.empty?

        cond = "(#{rank_sql}) IN (#{ranks.join(',')})"
        operator == '!' ? "NOT (#{cond})" : cond
      end

      # SQL condition for the customer text filter.
      # Supported operators: ~ (contains), !~ (does not contain),
      #                      = (equals), ! (does not equal)
      # Matches name OR email of the resolved customer contact (also covers
      # the "Kunden-E-Mail" column, so no separate email filter is needed).
      def sql_for_helpdesk_kunde_field(field, operator, value)
        conn   = ActiveRecord::Base.connection
        search = value.first.to_s

        pattern = case operator
                  when '~', '!~' then conn.quote('%' + search + '%')
                  else                conn.quote(search)
                  end
        like_op = (operator == '=' || operator == '!') ? '=' : 'LIKE'

        exists = <<~SQL.strip
          EXISTS (
            SELECT 1 FROM helpdesk_contacts hc
            WHERE hc.id = #{HELPDESK_CUSTOMER_CONTACT_ID_SQL}
              AND (LOWER(COALESCE(hc.name, '')) #{like_op} LOWER(#{pattern})
                OR LOWER(hc.email) #{like_op} LOWER(#{pattern}))
          )
        SQL

        operator.start_with?('!') ? "NOT (#{exists})" : exists
      end
    end
  end
end
