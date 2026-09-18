# Which attachments may be blacklisted from the ticket page at all.
#
# Blacklisting deletes a file from every ticket of the project, so the button must
# not sit next to the ones that carry the evidence: an .eml, a .msg, a PDF or a
# screenshot. Both columns are guards on the *button*, not on ingestion - they
# decide what an agent is offered, never what arrives.
#
# NULL/blank inherits the central plugin setting, which in turn falls back to the
# constants in RedmineExpertHelpdesk::AttachmentBlacklist.
class AddBlacklistGuardsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_project_settings, :blacklist_types)
      add_column :helpdesk_project_settings, :blacklist_types, :string, :limit => 255
    end

    unless column_exists?(:helpdesk_project_settings, :blacklist_max_kb)
      add_column :helpdesk_project_settings, :blacklist_max_kb, :integer
    end
  end
end
