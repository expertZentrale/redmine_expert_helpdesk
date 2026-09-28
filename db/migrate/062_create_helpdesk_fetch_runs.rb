# One row per mailbox fetch that is in progress right now, deleted when it
# ends. Maintenance mode reports these so an operator can tell when it is safe
# to scale the pods down. The row lives in the database, not Rails.cache: the
# default cache store is per process, and the fetch may run on any replica.
class CreateHelpdeskFetchRuns < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_fetch_runs)

    create_table :helpdesk_fetch_runs do |t|
      t.integer :mailbox_id
      t.string :mailbox_address
      t.string :host                                  # pod name in Kubernetes
      t.integer :pid
      t.integer :processed, :null => false, :default => 0
      t.datetime :started_at, :null => false
      t.datetime :heartbeat_at, :null => false
    end
  end
end
