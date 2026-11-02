# Redmine looks for an identical stored file after every new attachment
# (Attachment#reuse_existing_file_if_possible: same digest and filesize) and
# core has no index for that, so each upload and each imported mail scanned
# the whole attachments table. The helpdesk creates most attachments (every
# mail keeps its .eml), hence the index lives here.
#
# Own name instead of Rails' default, so a later core migration adding
# index_attachments_on_digest_and_filesize cannot collide with it; skipped when
# any index on these columns already exists (e.g. created by hand).
class AddDigestIndexToAttachments < ActiveRecord::Migration[6.1]
  INDEX_NAME = 'index_attachments_on_digest_filesize_helpdesk'

  def up
    return if index_exists?(:attachments, [:digest, :filesize])

    add_index :attachments, [:digest, :filesize], :name => INDEX_NAME
  end

  def down
    return unless index_exists?(:attachments, [:digest, :filesize], :name => INDEX_NAME)

    remove_index :attachments, :name => INDEX_NAME
  end
end
