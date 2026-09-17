# Journals whose text came from an AI answer draft.
#
# HelpdeskMessage#ai_drafted (migration 054) only covers a draft that was
# actually *sent* to the customer. An agent who inserts a draft and simply saves
# the ticket without ticking "send as mail" produces an ordinary journal note,
# and KnowledgeExtractor would read it back as ground truth when the ticket
# closes - the model would start learning from its own output.
#
# Recorded per journal rather than as a column on `journals`, so the plugin
# keeps to its own tables and leaves no orphan column behind if it is removed.
class CreateHelpdeskAiDraftedJournals < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_ai_drafted_journals)

    create_table :helpdesk_ai_drafted_journals do |t|
      t.integer  :journal_id, :null => false
      t.integer  :issue_id
      t.integer  :user_id
      t.datetime :created_at, :null => false
    end
    add_index :helpdesk_ai_drafted_journals, :journal_id, :unique => true,
              :name => 'index_hd_ai_drafted_journals_on_journal_id'
    add_index :helpdesk_ai_drafted_journals, :issue_id,
              :name => 'index_hd_ai_drafted_journals_on_issue_id'
  end
end
