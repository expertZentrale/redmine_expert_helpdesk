# Ein Protokolleintrag je KI-Aufruf (siehe Migration 033). Wird vom AiClient beim
# summarize/embed geschrieben – bei Erfolg mit Token/Dauer, bei Fehler mit
# error_class/http_status. Backing-Tabelle der projektbezogenen KI-Statistik
# (RedmineExpertHelpdesk::AiUsageStatistics).
class HelpdeskAiRequest < HelpdeskApplicationRecord
  # Nur created_at (kein updated_at) – Protokolleintrag ist unveraenderlich.
  self.record_timestamps = false

  REQUEST_TYPES = %w[summary kb_extract kb_embed kb_retrieve].freeze

  belongs_to :project, :optional => true
  belongs_to :issue,   :optional => true

  validates :request_type, :presence => true

  scope :successful, -> { where(:success => true) }
  scope :failed,     -> { where(:success => false) }
  scope :in_range,   ->(from, to) { where(:created_at => from...to) }

  before_create { self.created_at ||= Time.now }

  def total_tokens
    input_tokens.to_i + output_tokens.to_i
  end
end
