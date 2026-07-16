class CreateHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_project_settings do |t|
      t.integer :project_id,             :null => false
      t.boolean :send_reply_by_default,  :null => false, :default => true
      t.string  :reply_subject_template, :default => 'Re: [#{{issue.id}}] {{issue.subject}}'
      t.timestamps
    end
    add_index :helpdesk_project_settings, :project_id, :unique => true
  end
end
