# Per-project control of the completeness check for incoming mail
# ("Rueckfrage bei unvollstaendiger Meldung"):
# - info_request_mode: off | heuristic | ai (evaluate the initial mail, and how?)
# - the info_request_* rule columns configure the heuristic mode
# - info_request_ai_prompt/-_mode combine the project prompt with the central
#   default prompt, exactly like ai_prompt/ai_prompt_mode do for summaries
# - info_request_subject/-_body override the central mail templates
# - info_request_status_id optionally moves the ticket to "waiting for customer"
class AddInfoRequestSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      unless column_exists?(:helpdesk_project_settings, :info_request_mode)
        t.string :info_request_mode, :limit => 10, :default => 'off', :null => false
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_min_chars)
        t.integer :info_request_min_chars, :default => 200
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_min_words)
        t.integer :info_request_min_words, :default => 20
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_require_attachment)
        t.boolean :info_request_require_attachment, :default => false, :null => false
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_keywords)
        t.text :info_request_keywords
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_threshold)
        t.integer :info_request_threshold, :default => 1
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_ai_prompt)
        t.text :info_request_ai_prompt
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_ai_prompt_mode)
        t.string :info_request_ai_prompt_mode, :limit => 10, :default => 'inherit'
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_subject)
        t.string :info_request_subject, :limit => 255
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_body)
        t.text :info_request_body
      end
      unless column_exists?(:helpdesk_project_settings, :info_request_status_id)
        t.integer :info_request_status_id
      end
    end
  end
end
