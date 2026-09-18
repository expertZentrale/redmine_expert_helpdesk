# Per-project blacklist of attachment contents, keyed by the SHA-256 of the file.
#
# Business mail carries the same signature logo, social-media icon and tracking
# pixel on every single message, and MailHandler stores each copy as a real
# attachment - so a busy ticket collects a dozen of them. An agent blacklists one
# from the ticket page and every later copy is dropped during ingestion.
#
# The digest is the file content, not the name: "image001.png" is whatever the
# sender's mail client numbered first, and two customers' logos share it.
class CreateHelpdeskAttachmentBlacklists < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_attachment_blacklists)

    create_table :helpdesk_attachment_blacklists do |t|
      t.integer  :project_id,   :null => false
      t.string   :digest,       :null => false, :limit => 64
      # Name, size and type of the copy the agent blacklisted. Display only - the
      # match is the digest alone - but a list of bare hashes is unreviewable.
      t.string   :filename,     :limit => 255
      t.bigint   :filesize,     :null => false, :default => 0
      t.string   :content_type, :limit => 255
      t.integer  :user_id
      # How often the filter has dropped this file since, so the settings list
      # shows which entries earn their keep.
      t.integer  :hit_count,    :null => false, :default => 0
      t.datetime :last_hit_at
      t.datetime :created_on,   :null => false
    end

    # Explicit index names: the generated ones would be close to MySQL's 64-char limit.
    add_index :helpdesk_attachment_blacklists, [:project_id, :digest],
              :unique => true, :name => 'index_hd_att_blacklists_on_project_and_digest'
    add_index :helpdesk_attachment_blacklists, :filesize,
              :name => 'index_hd_att_blacklists_on_filesize'
  end
end
