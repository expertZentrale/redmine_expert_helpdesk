# Steuerung, wie die Postfach-Fusszeile mit der zentralen Signatur kombiniert wird:
#   inherit  - zentrale Signatur verwenden (Standard)
#   prepend  - Postfach-Fusszeile VOR der zentralen Signatur einfuegen
#   override - nur die Postfach-Fusszeile verwenden
class AddFooterModeToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_mailboxes, :footer_mode)
      add_column :helpdesk_mailboxes, :footer_mode, :string, :limit => 20, :default => 'inherit', :null => false
    end
  end
end
