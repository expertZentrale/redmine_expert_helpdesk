# A background run of the legacy contact import (kind 'import') or the EML
# attachment repair (kind 'fix_attachments'). The controller creates the row and
# enqueues HelpdeskLegacyImportJob; the status page polls it until it finishes.
class HelpdeskLegacyImportRun < ActiveRecord::Base
  KINDS    = %w[import fix_attachments].freeze
  ACTIVE   = %w[queued running].freeze
  FINISHED = %w[done failed].freeze

  # The :async ActiveJob adapter keeps jobs in process memory, so a restart or a
  # crashed worker leaves the row "running" forever. Progress updates touch
  # updated_at, so a run without a heartbeat for this long is treated as dead
  # and no longer blocks a new one.
  STALE_AFTER = 1.hour

  # Write the progress counter at most every N rows - one UPDATE per row would
  # double the cost of the import it reports on.
  PROGRESS_EVERY = 100

  belongs_to :user, :optional => true

  validates :kind, :inclusion => { :in => KINDS }
  validates :status, :inclusion => { :in => ACTIVE + FINISHED }

  scope :active, -> { where(:status => ACTIVE).where('updated_at > ?', STALE_AFTER.ago) }

  # The live run of this kind, if any. Import and repair both rewrite the same
  # helpdesk_messages rows, so either one blocks the other.
  def self.current
    active.order(:id => :desc).first
  end

  def self.latest(kind)
    where(:kind => kind).order(:id => :desc).first
  end

  def active?
    ACTIVE.include?(status) && !stale?
  end

  def finished?
    FINISHED.include?(status)
  end

  def stale?
    ACTIVE.include?(status) && updated_at && updated_at <= STALE_AFTER.ago
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

  def start!
    update_columns(:status => 'running', :started_at => Time.current, :updated_at => Time.current)
  end

  # Called from inside the import loop; throttled so only every
  # PROGRESS_EVERY-th row (plus phase changes and the last row) hits the DB.
  def progress!(phase, done, total)
    return if phase == self.phase && done < total && (done % PROGRESS_EVERY).nonzero?

    update_columns(:phase => phase, :progress_done => done, :progress_total => total,
                   :updated_at => Time.current)
  end

  def finish!(counters)
    update_columns(:status => 'done', :result => ActiveSupport::JSON.encode(counters.to_h),
                   :finished_at => Time.current, :updated_at => Time.current)
  end

  def fail!(message)
    update_columns(:status => 'failed', :error_message => message.to_s.truncate(2000),
                   :finished_at => Time.current, :updated_at => Time.current)
  end
end
