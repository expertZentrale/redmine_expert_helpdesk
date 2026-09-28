require 'socket'

# A mailbox fetch in progress: MailProcessor#process_all creates the row before
# it looks at the mailbox and deletes it when it is done, so "no live rows"
# means no pod is processing mail. The heartbeat moves with every message; a
# pod killed mid-fetch leaves its row behind, which stops counting once the
# heartbeat is older than STALE_AFTER and is purged by the next status read.
class HelpdeskFetchRun < ActiveRecord::Base
  # One message is MIME download + MailHandler + attachments; minutes, not
  # hours. Generous so a slow message never reads as "idle".
  STALE_AFTER = 10.minutes

  scope :live,  -> { where('heartbeat_at > ?', STALE_AFTER.ago) }
  scope :stale, -> { where('heartbeat_at <= ?', STALE_AFTER.ago) }

  # Registers the fetch for the duration of the block. The row is removed even
  # when the block raises or returns early.
  def self.track(mailbox)
    now = Time.current
    run = create!(:mailbox_id => mailbox.id, :mailbox_address => mailbox.mailbox_address,
                  :host => Socket.gethostname, :pid => Process.pid,
                  :started_at => now, :heartbeat_at => now)
    yield run
  ensure
    run&.delete
  end

  def heartbeat!(processed)
    update_columns(:processed => processed, :heartbeat_at => Time.current)
  end

  def self.purge_stale!
    stale.delete_all
  end
end
