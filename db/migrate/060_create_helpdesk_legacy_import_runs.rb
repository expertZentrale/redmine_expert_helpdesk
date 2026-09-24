# One row per background run of the legacy contact import or the EML attachment
# repair. Both used to run inside the admin's request and hit the browser /
# reverse-proxy timeout on large redmine_contacts datasets; now a job does the
# work and the browser only polls this row.
#
# Status lives in the database rather than Rails.cache: the default cache store
# is per process (file store), so on a multi-replica deployment the poll could
# land on a pod that never saw the run.
class CreateHelpdeskLegacyImportRuns < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_legacy_import_runs)

    create_table :helpdesk_legacy_import_runs do |t|
      t.string :kind, :null => false, :limit => 30        # import | fix_attachments
      t.string :status, :null => false, :limit => 20      # queued | running | done | failed
      t.text :project_ids                                 # JSON; nil = all projects
      t.string :phase, :limit => 30
      t.integer :progress_done, :null => false, :default => 0
      t.integer :progress_total, :null => false, :default => 0
      t.text :result                                      # JSON counters of the finished run
      t.text :error_message
      t.integer :user_id
      t.datetime :started_at
      t.datetime :finished_at
      t.timestamps :null => false
    end

    add_index :helpdesk_legacy_import_runs, [:kind, :status],
              :name => 'index_hd_legacy_import_runs_on_kind_and_status'
  end
end
