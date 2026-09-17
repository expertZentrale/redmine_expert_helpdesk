# Marks one journal as "the text in here came from an AI answer draft".
#
# Written by the controller_issues_edit_after_save hook when the issue form
# carried hd_ai_drafted, i.e. the agent inserted a draft and saved - whether or
# not the note was also mailed to the customer. Read by KnowledgeExtractor, so
# the knowledge base never ingests the model's own prose as a solution.
class HelpdeskAiDraftedJournal < HelpdeskApplicationRecord
  # Immutable log entry, created_at only.
  self.record_timestamps = false

  belongs_to :journal, :optional => true
  belongs_to :issue,   :optional => true
  belongs_to :user,    :optional => true

  validates :journal_id, :presence => true, :uniqueness => true

  before_create { self.created_at ||= Time.now }

  # Journal ids to keep out of knowledge-base input. Guarded: the table arrives
  # with migration 056 and this runs on every ticket close.
  def self.journal_ids_for(issue_id)
    return [] unless table_exists?

    where(:issue_id => issue_id).pluck(:journal_id).compact
  rescue StandardError
    []
  end
end
