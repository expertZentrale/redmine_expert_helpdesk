# Who triggered the AI call.
#
# The summary, completeness and knowledge-base calls run in background jobs with
# no acting user, so the column stays nil for them. The answer draft is
# different: an agent presses a button and the result is proposed to a customer,
# so "who asked the model to write to this customer" has to be answerable.
class AddUserToHelpdeskAiRequests < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_ai_requests, :user_id)
      add_column :helpdesk_ai_requests, :user_id, :integer
      add_index  :helpdesk_ai_requests, :user_id, :name => 'index_hd_ai_requests_on_user_id'
    end
  end
end
