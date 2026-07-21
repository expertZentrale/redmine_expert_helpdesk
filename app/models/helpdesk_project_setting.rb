# Projekt-spezifische Helpdesk-Einstellungen (eine Zeile pro Projekt).
# Wird bei Bedarf per find_or_initialize_by angelegt; Defaults kommen aus der Migration.
class HelpdeskProjectSetting < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :reply_status, :class_name => 'IssueStatus', :optional => true

  DEFAULT_SUBJECT_TEMPLATE = 'Re: [#{{issue.id}}] {{issue.subject}}'.freeze

  # Aktion bei Phishing-Treffer: Links neutralisieren oder Mail in Quarantaene
  PHISHING_ACTIONS = %w[neutralize quarantine].freeze

  # KI-Zusammenfassung: Umfang (nur Erstmail vs. auch Journal-Antworten) und
  # wie der Projekt-Prompt mit dem zentralen Default-Prompt kombiniert wird.
  AI_SCOPES       = %w[initial initial_and_replies].freeze
  AI_PROMPT_MODES = %w[inherit extend override].freeze

  validates :phishing_action, :inclusion => { :in => PHISHING_ACTIONS }, :allow_nil => true
  validates :ai_summary_scope, :inclusion => { :in => AI_SCOPES }, :allow_nil => true
  validates :ai_prompt_mode,   :inclusion => { :in => AI_PROMPT_MODES }, :allow_nil => true
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

  # KI-Zusammenfassung auch fuer Journal-Antworten (nicht nur die Erstmail)?
  def ai_summary_for_replies?
    ai_summary_scope == 'initial_and_replies'
  end

  # Effektiver Prompt: erben (zentraler Default), erweitern (zentral + Projekt)
  # oder ersetzen (nur Projekt). Analog zu HelpdeskMailbox#effective_footer_template.
  def effective_ai_prompt
    global  = Setting.plugin_redmine_expert_helpdesk['ai_prompt'].to_s
    project = ai_prompt.to_s
    case ai_prompt_mode.presence || 'inherit'
    when 'override'
      project.presence || global
    when 'extend'
      [global.presence, project.presence].compact.join("\n\n")
    else # inherit
      global.presence || project
    end
  end
end
