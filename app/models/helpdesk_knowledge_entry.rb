# Wissensbasis-Eintrag (System of Record) je geloestem Ticket. Haelt das extrahierte
# {Problem, Loesung}, den Kuratierungsstatus und die Referenz auf den
# Vektor-Punkt im externen Store. Nur `approved`-Eintraege sind im Vektor-Store
# und damit fuer die Suche sichtbar.
#
# The vector store holds a copy only: editing a payload there leaves the vector
# computed from the old text, so every change goes through this row and is
# re-embedded (HelpdeskKnowledgeIngestJob.index_entry) or removed (unindex).
class HelpdeskKnowledgeEntry < HelpdeskApplicationRecord
  belongs_to :issue,      :optional => true
  belongs_to :project,    :optional => true
  belongs_to :updated_by, :class_name => 'User', :optional => true

  # skipped  = the model found no solution in the ticket
  # rejected = a person judged the entry wrong; kept so a re-close does not re-ingest it
  STATUSES = %w[pending approved skipped rejected].freeze

  validates :project_id, :issue_id, :presence => true
  validates :issue_id, :uniqueness => true
  validates :status, :inclusion => { :in => STATUSES }
  validate  :issue_belongs_to_project, :on => :create

  scope :approved, -> { where(:status => 'approved') }
  scope :pending,  -> { where(:status => 'pending') }

  # Case-insensitive free text over problem and solution.
  scope :search, lambda { |q|
    safe = "%#{sanitize_sql_like(q.to_s.strip.downcase)}%"
    where('LOWER(problem) LIKE ? OR LOWER(solution) LIKE ?', safe, safe)
  }

  def approved?
    status == 'approved'
  end

  def pending?
    status == 'pending'
  end

  def skipped?
    status == 'skipped'
  end

  def rejected?
    status == 'rejected'
  end

  # Edited, approved or rejected by a person (see migration 061).
  def curated?
    curated_at.present?
  end

  def curate!(user, attrs = {})
    update(attrs.merge(:updated_by_id => user&.id, :curated_at => Time.current))
  end

  # Brings the vector store in line with the row after a person changed it:
  # approved -> (re-)embed, any other status -> must not be searchable. Synchronous,
  # so the caller (tab or REST API) can report at once whether the store took it.
  # Returns one of SYNC_RESULTS.
  #
  # Runs under the row lock and acts on the row as it is then, not on this
  # request's copy: two overlapping requests (an approve and a reject, or an edit
  # and a delete) otherwise finish their store calls in either order, and the
  # slower one undoes the faster one - a stale upsert brings back rejected text, a
  # late delete drops a newer approved vector. Serialized, the last sync always
  # sees the last write. The lock is held across the embedding call, so another
  # write to the same entry waits for it. index_fenced still guards against the
  # ingest job, which embeds without the lock.
  SYNC_RESULTS = %i[indexed not_configured problem_blank index_failed removed unindex_failed].freeze

  def sync_vector!
    self.class.transaction { lock_current ? sync_locked : :removed }
  end

  # Delete with the point removed first, under the same lock as sync_vector!, so
  # no approval can re-embed the entry between the two steps. Once the row is
  # gone nothing records which point to remove, so a failed removal keeps the row
  # and returns false.
  def destroy_with_vector!
    self.class.transaction do
      next true unless lock_current
      next false if point_id.present? && !self.class.unindex(self)

      destroy
      true
    end
  end

  # Removes the entry's point from the vector store. Returns false (and logs) on
  # failure instead of raising: the SQL row is the system of record, and a stale
  # point is cleared by the next project reindex.
  def self.unindex(entry)
    store = RedmineExpertHelpdesk::KnowledgeStore.for(Setting.plugin_redmine_expert_helpdesk)
    return false unless store.configured?

    store.delete(entry.project_id, entry.id)
    entry.update_columns(:point_id => nil) if entry.persisted? && !entry.destroyed?
    true
  rescue => e
    Rails.logger.warn("[helpdesk][kb] Removing point failed (entry ##{entry.id}): #{e.class}: #{e.message}")
    false
  end

  private

  # Takes the row lock and reloads; false when the row is gone (a delete removed
  # its point before the row).
  def lock_current
    lock!
    true
  rescue ActiveRecord::RecordNotFound
    false
  end

  def sync_locked
    if approved?
      if !RedmineExpertHelpdesk::AiFeatures.kb_ready?
        :not_configured
      elsif problem.blank?
        :problem_blank
      else
        result = HelpdeskKnowledgeIngestJob.index_fenced(self)
        reload if self.class.exists?(id)
        result
      end
    elsif point_id.present? && !self.class.unindex(self)
      # point_id stays set, so the entry still shows as indexed and the next
      # "Rebuild index" removes the point.
      :unindex_failed
    else
      :removed
    end
  end

  # Entries are strictly per project; a manual entry must not reference a ticket
  # of another project (its text would leak into this project's retrieval).
  def issue_belongs_to_project
    return if issue_id.blank? || project_id.blank?

    iss = Issue.find_by(:id => issue_id)
    if iss.nil?
      errors.add(:issue_id, :invalid)
    elsif iss.project_id != project_id
      errors.add(:issue_id, :invalid)
    end
  end
end
