class CreateHelpdeskContacts < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_contacts do |t|
      t.string :email, :null => false
      t.string :name
      t.string :company
      t.text   :notes
      t.timestamps
    end
    add_index :helpdesk_contacts, :email, :unique => true
  end
end
