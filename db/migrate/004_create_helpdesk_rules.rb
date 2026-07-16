class CreateHelpdeskRules < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_rules do |t|
      t.references :helpdesk_mailbox, :null => false, :index => true
      t.integer :position, :default => 1, :null => false
      t.string :condition_field, :null => false, :default => 'subject'
      t.string :operator, :null => false, :default => 'contains'
      t.string :condition_value, :null => false
      t.string :action_type, :null => false
      t.string :action_value
      t.timestamps
    end
  end
end
