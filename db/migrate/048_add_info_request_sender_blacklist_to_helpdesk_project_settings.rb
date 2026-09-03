# Senders the completeness check must never ask for more information.
# Veeam job reports, cron mails and monitoring alerts are legitimate tickets, but
# there is no author behind them who could answer a follow-up - the mail would
# bounce or, worse, loop. One entry per line: full address, bare domain or
# "@domain".
class AddInfoRequestSenderBlacklistToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :info_request_sender_blacklist)

    add_column :helpdesk_project_settings, :info_request_sender_blacklist, :text
  end
end
