# Phishing-Pruefung pro Projekt aktivierbar; Aktion bei Treffer konfigurierbar.
class AddPhishingSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_project_settings, :phishing_check_enabled)
      add_column :helpdesk_project_settings, :phishing_check_enabled, :boolean, :default => false, :null => false
    end
    unless column_exists?(:helpdesk_project_settings, :phishing_action)
      add_column :helpdesk_project_settings, :phishing_action, :string, :default => 'neutralize'
    end
  end
end
