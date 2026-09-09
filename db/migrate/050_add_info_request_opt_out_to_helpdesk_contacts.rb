# Per-customer switch for the completeness check: this contact is never asked for
# more information.
#
# The project-wide list (info_request_sender_blacklist) needs a helpdesk admin and
# an address known in advance. An agent who has just seen a Veeam report land as a
# ticket only has the contact in front of them - this flag is the same decision,
# taken where it is noticed. Both are read by HelpdeskCompletenessJob.
class AddInfoRequestOptOutToHelpdeskContacts < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_contacts, :info_request_opt_out)

    add_column :helpdesk_contacts, :info_request_opt_out, :boolean,
               :default => false, :null => false
  end
end
