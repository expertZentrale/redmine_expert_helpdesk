# Marks an outgoing reply whose body came from an AI answer draft.
#
# Two reasons, and the second is the important one:
# 1. Months later, "was this written by a person or by a model?" is a question
#    somebody will ask about a specific mail. Without this column nothing in the
#    database can answer it - HelpdeskAiRequest records that a draft was
#    generated, not that it was sent.
# 2. KnowledgeExtractor reads journal notes back out when a ticket closes. Left
#    unmarked, a draft written today is re-ingested as ground truth tomorrow and
#    the model starts learning from its own output.
class AddAiDraftedToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_messages, :ai_drafted)
      add_column :helpdesk_messages, :ai_drafted, :boolean, :default => false, :null => false
    end
  end
end
