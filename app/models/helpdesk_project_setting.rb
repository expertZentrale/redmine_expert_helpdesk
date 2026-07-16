# Projekt-spezifische Helpdesk-Einstellungen (eine Zeile pro Projekt).
# Wird bei Bedarf per find_or_initialize_by angelegt; Defaults kommen aus der Migration.
class HelpdeskProjectSetting < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :reply_status, :class_name => 'IssueStatus', :optional => true

  DEFAULT_SUBJECT_TEMPLATE = 'Re: [#{{issue.id}}] {{issue.subject}}'.freeze

  # Aktion bei Phishing-Treffer: Links neutralisieren oder Mail in Quarantaene
  PHISHING_ACTIONS = %w[neutralize quarantine].freeze

  validates :phishing_action, :inclusion => { :in => PHISHING_ACTIONS }, :allow_nil => true
  validates :sla_work_start, :sla_work_end,
            :format => { :with => /\A\d{1,2}:\d{2}\z/ }, :allow_blank => true
  validates :sla_reaction_minutes, :sla_solution_minutes,
            :numericality => { :only_integer => true, :greater_than => 0 }, :allow_nil => true

  def self.for_project(project)
    find_or_initialize_by(:project_id => project.id)
  end

  # ISO-Wochentage (Mo=1..So=7) als Integer-Array
  def sla_work_days_array
    sla_work_days.to_s.split(',').map(&:to_i).select { |d| (1..7).cover?(d) }
  end

  def effective_subject_template
    reply_subject_template.presence || DEFAULT_SUBJECT_TEMPLATE
  end

  def effective_phishing_action
    PHISHING_ACTIONS.include?(phishing_action) ? phishing_action : 'neutralize'
  end
end
