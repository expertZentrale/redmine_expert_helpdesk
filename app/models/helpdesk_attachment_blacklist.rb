# One blacklisted file content per row, scoped to a project.
#
# Signature logos, social-media icons and tracking pixels arrive as real
# attachments on every mail of a thread. An agent blacklists one from the ticket
# page (see HelpdeskAttachmentBlacklistsController) and RedmineExpertHelpdesk::
# AttachmentBlacklist drops every later copy during ingestion.
#
# The key is the SHA-256 of the file content. File names are worthless here:
# Outlook numbers embedded images per mail ("image001.png"), so the same name
# means nothing and two different senders' logos collide under it.
require 'digest'

class HelpdeskAttachmentBlacklist < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :user, :optional => true

  validates :project_id, :presence => true
  validates :digest, :presence => true,
                     :format => { :with => /\A\h{64}\z/, :message => :invalid }
  validates :digest, :uniqueness => { :scope => :project_id, :case_sensitive => false }

  scope :sorted, lambda { order(:created_on => :desc) }

  # The SHA-256 of the attachment's bytes, or nil when the file is unreadable.
  #
  # Deliberately computed here instead of reading Attachment#digest: that column
  # is Redmine's, it held MD5 before Redmine 3.4, and if its algorithm ever moves
  # again every existing blacklist row would silently stop matching. Reading a
  # file that was just written by MailHandler costs nothing next to the fetch
  # that downloaded it.
  def self.digest_for(attachment)
    path = attachment.respond_to?(:diskfile) ? attachment.diskfile : nil
    return nil if path.blank? || !File.exist?(path)

    Digest::SHA256.file(path).hexdigest
  rescue StandardError => e
    Rails.logger.warn "Helpdesk: digest of attachment ##{attachment.try(:id)} failed: #{e.message}"
    nil
  end

  # The blacklist entry that covers this file content in this project, or nil.
  def self.entry_for(project, digest)
    return nil if project.nil? || digest.blank?

    find_by(:project_id => project.id, :digest => digest)
  end

  # Records that the filter dropped a copy. update_all, not update: the counter is
  # bookkeeping and must never fail an ingestion over a validation or a race.
  def register_hit!
    self.class.where(:id => id)
        .update_all(['hit_count = hit_count + 1, last_hit_at = ?', Time.current])
  end

  def label
    filename.presence || digest[0, 12]
  end
end
