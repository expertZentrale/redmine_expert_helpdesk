# Projekt-spezifische Einstellungen fuer KI-Zusammenfassungen eingehender Mails.
# Provider/Key/Modell/Default-Prompt liegen zentral (Plugin-Settings); hier nur
# die pro-Projekt-Steuerung: aktiv, Umfang (nur Erstmail / auch Antworten),
# Prompt-Modus (erben/erweitern/ersetzen) + Projekt-Prompt und die Auswahl,
# welche Anhaenge (Metadaten / extrahierter Text / Bilder) an die KI gehen.
class AddAiSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.boolean :ai_summary_enabled, :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_summary_enabled)
      t.string  :ai_summary_scope,   :limit => 20, :default => 'initial'  unless column_exists?(:helpdesk_project_settings, :ai_summary_scope)
      t.string  :ai_prompt_mode,     :limit => 20, :default => 'inherit'  unless column_exists?(:helpdesk_project_settings, :ai_prompt_mode)
      t.text    :ai_prompt                                                unless column_exists?(:helpdesk_project_settings, :ai_prompt)
      t.boolean :ai_attach_metadata, :default => true,  :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_metadata)
      t.boolean :ai_attach_text,     :default => false, :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_text)
      t.boolean :ai_attach_images,   :default => false, :null => false    unless column_exists?(:helpdesk_project_settings, :ai_attach_images)
    end
  end
end
