# One-off cleanup of what deleting issues and projects through core Redmine
# used to leave behind (#46, #47), before Issue and Project owned their
# helpdesk rows:
# - ticket infos and messages of issues that no longer exist (a message
#   cannot be unlinked: issue_id is NOT NULL and the model requires an issue),
# - contacts of projects that no longer exist. These were invisible in every
#   list and could not be deleted through the API, not even by an admin.
#   Their remaining message and ticket-info links are unlinked first, exactly
#   what the contact's own :dependent => :nullify would have done.
# Nothing to undo: every row removed here pointed at a record that is gone.
class CleanUpOrphanedHelpdeskRows < ActiveRecord::Migration[6.1]
  def up
    issues   = "SELECT id FROM #{quote_table_name(:issues)}"
    projects = "SELECT id FROM #{quote_table_name(:projects)}"

    execute "DELETE FROM helpdesk_ticket_infos WHERE issue_id NOT IN (#{issues})"
    execute "DELETE FROM helpdesk_messages WHERE issue_id NOT IN (#{issues})"

    orphans = "SELECT id FROM (SELECT id FROM helpdesk_contacts " \
              "WHERE project_id IS NOT NULL AND project_id NOT IN (#{projects})) AS orphaned_contacts"
    execute "UPDATE helpdesk_messages SET helpdesk_contact_id = NULL WHERE helpdesk_contact_id IN (#{orphans})"
    execute "UPDATE helpdesk_ticket_infos SET helpdesk_contact_id = NULL WHERE helpdesk_contact_id IN (#{orphans})"
    execute "DELETE FROM helpdesk_contacts WHERE id IN (#{orphans})"
  end

  def down
    # Irreversible by nature, and harmless to step over.
  end
end
