# Answer templates ("Textbausteine") an agent can insert into the note field
# while replying to a customer. project_id NULL marks a global template that is
# offered in every helpdesk project; a row with a project_id belongs to that
# project alone. One table for both scopes keeps the picker a single query.
class CreateHelpdeskReplyTemplates < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_reply_templates)

    create_table :helpdesk_reply_templates do |t|
      t.integer :project_id
      t.string  :name,    :null => false, :limit => 255
      t.text    :content, :null => false
      t.integer :position
      t.boolean :enabled, :null => false, :default => true
      t.timestamps
    end
    # Explicit index name: the generated one would be close to MySQL's 64-char limit.
    add_index :helpdesk_reply_templates, [:project_id, :position],
              :name => 'index_hd_reply_templates_on_project_and_position'
  end
end
