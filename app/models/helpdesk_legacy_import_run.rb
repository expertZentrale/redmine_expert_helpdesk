# A background run of the legacy contact import (kind 'import'), the EML
# attachment repair (kind 'fix_attachments') or its reverse for projects still on
# RedmineUP's helpdesk (kind 'restore_attachments'). The controller claims a row and
# enqueues HelpdeskLegacyImportJob; the status page polls it until it finishes.
#
# Import and repair both rewrite helpdesk_messages, so only one run may be live.
# That is enforced by the database, not by checking first: active_lock is
# 'active' while a run is queued/running and carries a unique index, so a second
# claim fails on insert. Every write the job makes is fenced on still holding
# that lock - a worker whose run was retired as stale stops at its next
# checkpoint instead of rewriting data alongside its replacement.
class HelpdeskLegacyImportRun < ActiveRecord::Base
  KINDS    = %w[import fix_attachments restore_attachments].freeze
  ACTIVE   = %w[queued running].freeze
  FINISHED = %w[done failed stale].freeze
  LOCK     = 'active'.freeze

  # The :async ActiveJob adapter keeps jobs in process memory, so a restart or a
  # crashed worker leaves the row "running" forever. Progress updates touch
  # updated_at, so a run without a heartbeat for this long is retired by the
  # next claim.
  STALE_AFTER = 1.hour

  # Write the progress counter at most every N rows - one UPDATE per row would
  # double the cost of the import it reports on.
  PROGRESS_EVERY = 100

  # ...but never less often than this. The time bound is what fences a retired
  # worker: one that stalled past STALE_AFTER sees the gap on its very next row
  # and hits Superseded before writing it, instead of up to PROGRESS_EVERY rows later.
  HEARTBEAT_EVERY = 30.seconds

  # Raised from a checkpoint when this run no longer holds the lock.
  class Superseded < StandardError; end

  belongs_to :user, :optional => true

  validates :kind, :inclusion => { :in => KINDS }
  validates :status, :inclusion => { :in => ACTIVE + FINISHED }

  scope :locked, -> { where(:active_lock => LOCK) }
  scope :active, -> { locked.where('updated_at > ?', STALE_AFTER.ago) }

  # The live run, if any (either kind).
  def self.current
    active.order(:id => :desc).first
  end

  # Atomically creates the live run, or returns nil when another one holds the
  # lock. A run without heartbeat is retired first so it cannot block forever.
  def self.claim!(kind, user, project_ids = nil)
    locked.where('updated_at <= ?', STALE_AFTER.ago)
          .update_all(:status => 'stale', :active_lock => nil,
                      :finished_at => Time.current, :updated_at => Time.current)

    run = new(:kind => kind, :status => 'queued', :user => user, :active_lock => LOCK)
    run.project_id_list = project_ids
    run.save!
    run
  rescue ActiveRecord::RecordNotUnique
    nil
  end

  def active?
    ACTIVE.include?(status) && !stale?
  end

  def finished?
    FINISHED.include?(status)
  end

  # Still marked live, but without heartbeat - shown as interrupted until the
  # next claim retires it.
  def stale?
    ACTIVE.include?(status) && updated_at.present? && updated_at <= STALE_AFTER.ago
  end

  def project_id_list
    project_ids.present? ? ActiveSupport::JSON.decode(project_ids) : nil
  end

  def project_id_list=(ids)
    self.project_ids = ids.nil? ? nil : ActiveSupport::JSON.encode(Array(ids).map(&:to_s))
  end

  def result_hash
    result.present? ? ActiveSupport::JSON.decode(result).symbolize_keys : {}
  end

  # queued -> running; false when the run was retired or already picked up,
  # so a duplicate or late job does nothing.
  def start!
    fenced_update(%w[queued], :status => 'running', :started_at => Time.current)
  end

  # Called from inside the import loop before each row; throttled so only every
  # PROGRESS_EVERY-th row (plus phase changes, the last row and anything after a
  # HEARTBEAT_EVERY gap) hits the DB. Raises Superseded once the run lost its lock.
  def progress!(phase, done, total)
    return if phase == self.phase && done < total && (done % PROGRESS_EVERY).nonzero? &&
              @heartbeat_at && @heartbeat_at > HEARTBEAT_EVERY.ago

    self.phase = phase
    return if fenced_update(%w[running], :phase => phase, :progress_done => done, :progress_total => total)

    raise Superseded, "legacy import run ##{id} was superseded"
  end

  def finish!(counters)
    fenced_update(ACTIVE, :status => 'done', :result => ActiveSupport::JSON.encode(counters.to_h),
                  :active_lock => nil, :finished_at => Time.current)
  end

  def fail!(message)
    fenced_update(ACTIVE, :status => 'failed', :error_message => message.to_s.truncate(2000),
                  :active_lock => nil, :finished_at => Time.current)
  end

  private

  # UPDATE ... WHERE the row is still ours; true when it was.
  def fenced_update(from_statuses, attrs)
    attrs = attrs.merge(:updated_at => Time.current)
    updated = self.class.locked.where(:id => id, :status => from_statuses).update_all(attrs)
    return false if updated.zero?

    attrs.each { |k, v| self[k] = v }
    clear_changes_information
    @heartbeat_at = Time.current
    true
  end
end
