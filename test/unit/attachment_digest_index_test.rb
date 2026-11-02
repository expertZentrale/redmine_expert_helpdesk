require File.expand_path('../../test_helper', __FILE__)

# Migration 069: lookups of attachments by content (Redmine's duplicate-file
# check after every new attachment, the AI summary's recurring-logo check)
# need an index on digest, or they scan the whole table on large installs.
class AttachmentDigestIndexTest < ActiveSupport::TestCase
  def test_attachments_have_an_index_starting_with_digest_and_filesize
    columns = ActiveRecord::Base.connection.indexes(:attachments).map(&:columns)
    assert_includes columns, %w(digest filesize), "indexes on attachments: #{columns.inspect}"
  end
end
