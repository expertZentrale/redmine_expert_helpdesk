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
