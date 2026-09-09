# Who gave the first reaction. Recorded together with first_response_at, so the
# ticket statistics can attribute the first response to an agent without relying
# on a journal note (the reply mail and the note are two separate requests, and
# the second one can fail or be abandoned).
#
# Best-effort backfill: the public note that was written at the recorded moment
# (the hook records the journal's own created_on; the reply form records a time a
# few seconds before the note is saved).
class AddFirstResponseByToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def up
    unless column_exists?(:helpdesk_ticket_infos, :first_response_by_id)
      add_column :helpdesk_ticket_infos, :first_response_by_id, :integer
    end

    # The backfill runs regardless of the column check and only touches rows that
    # are still empty, so a rerun after a partial first run is safe and cheap.
    anonymous_id = User.anonymous.id
    HelpdeskTicketInfo.reset_column_information
    HelpdeskTicketInfo.where.not(:first_response_at => nil).where(:first_response_by_id => nil).find_each do |info|
      journal = Journal.where(:journalized_type => 'Issue', :journalized_id => info.issue_id,
                              :private_notes => false)
                       .where("COALESCE(notes, '') <> ''")
                       .where(:created_on => (info.first_response_at - 5)..(info.first_response_at + 120))
                       .where.not(:user_id => [nil, anonymous_id])
                       .order(:created_on, :id).first
      info.update_columns(:first_response_by_id => journal.user_id) if journal
    end
  end

  def down
    remove_column :helpdesk_ticket_infos, :first_response_by_id if column_exists?(:helpdesk_ticket_infos, :first_response_by_id)
  end
end
