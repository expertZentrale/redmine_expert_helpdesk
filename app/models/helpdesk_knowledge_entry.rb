# Wissensbasis-Eintrag (System of Record) je geloestem Ticket. Haelt das
# extrahierte {Problem, Loesung}, den Kuratierungsstatus und die Referenz auf den
# Vektor-Punkt im externen Store. Nur `approved`-Eintraege sind im Vektor-Store
# und damit fuer die Suche sichtbar.
class HelpdeskKnowledgeEntry < HelpdeskApplicationRecord
  belongs_to :issue,   :optional => true
  belongs_to :project, :optional => true

  STATUSES = %w[pending approved skipped].freeze

  validates :project_id, :issue_id, :presence => true
  validates :status, :inclusion => { :in => STATUSES }

  scope :approved, -> { where(:status => 'approved') }
  scope :pending,  -> { where(:status => 'pending') }

  def approved?
    status == 'approved'
  end

  def pending?
    status == 'pending'
  end

  def skipped?
    status == 'skipped'
  end
end
