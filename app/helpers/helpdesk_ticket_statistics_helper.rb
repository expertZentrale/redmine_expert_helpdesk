# View helpers of the ticket statistics (names of principals/contacts/statuses,
# percentages). Durations come from HelpdeskSlaStatisticsHelper#hd_stats_minutes.
module HelpdeskTicketStatisticsHelper
  def hd_ticket_stats_pct(value)
    return content_tag(:span, '–', :class => 'hd-stats-empty') if value.nil?

    "#{value} %"
  end

  # Row of the per-agent table -> name (User linked to its profile, Group plain,
  # nil = unassigned, unknown id = deleted).
  def hd_ticket_stats_principal(row)
    return l(:label_helpdesk_ticket_stats_unassigned) if row[:principal_id].nil?
    return "##{row[:principal_id]} (#{l(:label_helpdesk_ticket_stats_deleted)})" if row[:deleted]

    if row[:type] == 'User'
      link_to(row[:name], user_path(row[:principal_id]))
    else
      safe_join([row[:name], content_tag(:em, "(#{l(:label_group)})", :class => 'hd-stats-muted')], ' ')
    end
  end

  # Row of the per-customer table -> name (or email as fallback), linked to the
  # contact profile for users who may manage contacts. Email addresses are
  # rendered as plain text elsewhere, never as mailto links.
  def hd_ticket_stats_customer(row)
    return l(:label_helpdesk_ticket_stats_no_contact) if row[:contact_id].nil?
    return "##{row[:contact_id]} (#{l(:label_helpdesk_ticket_stats_deleted)})" if row[:deleted]

    label = row[:name].presence || row[:email].to_s
    if User.current.allowed_to?(:manage_helpdesk_contacts, @project)
      link_to(label, edit_helpdesk_contact_path(:project_id => @project, :id => row[:contact_id]))
    else
      label
    end
  end

  def hd_ticket_stats_status_name(row)
    row[:name].presence || "##{row[:id]}"
  end

  def hd_ticket_stats_conversation_bucket_label(key)
    l("label_helpdesk_ticket_stats_dist_#{key.to_s.tr('-', '_').sub('>', 'gt_')}", :default => key.to_s)
  end
end
