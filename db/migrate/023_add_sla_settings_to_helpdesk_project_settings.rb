# SLA-Einstellungen pro Projekt: Zielzeiten (Geschaeftsminuten), Arbeitszeiten
# (Wochentage + Zeitspanne) und Benachrichtigung bei Ueberschreitung.
class AddSlaSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.boolean  :sla_enabled,          :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :sla_enabled)
      t.datetime :sla_enabled_at unless column_exists?(:helpdesk_project_settings, :sla_enabled_at)
      t.integer  :sla_reaction_minutes unless column_exists?(:helpdesk_project_settings, :sla_reaction_minutes)
      t.integer  :sla_solution_minutes unless column_exists?(:helpdesk_project_settings, :sla_solution_minutes)
      t.string   :sla_work_days,  :limit => 20, :default => '1,2,3,4,5' unless column_exists?(:helpdesk_project_settings, :sla_work_days)
      t.string   :sla_work_start, :limit => 5,  :default => '08:00' unless column_exists?(:helpdesk_project_settings, :sla_work_start)
      t.string   :sla_work_end,   :limit => 5,  :default => '17:00' unless column_exists?(:helpdesk_project_settings, :sla_work_end)
      t.boolean  :sla_notify_enabled, :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :sla_notify_enabled)
      t.string   :sla_notify_email unless column_exists?(:helpdesk_project_settings, :sla_notify_email)
      t.integer  :sla_notify_user_id unless column_exists?(:helpdesk_project_settings, :sla_notify_user_id)
    end
  end
end
