# Projekt-spezifische Helpdesk-Einstellungen (eine Zeile pro Projekt).
# Wird bei Bedarf per find_or_initialize_by angelegt; Defaults kommen aus der Migration.
class HelpdeskProjectSetting < HelpdeskApplicationRecord
  belongs_to :project
  belongs_to :reply_status, :class_name => 'IssueStatus', :optional => true
  # Default assignee for new tickets: a user *or* a group, hence Principal.
  belongs_to :default_assigned_to, :class_name => 'Principal', :optional => true
  # Optional status the ticket is moved to after an automatic request for more
  # information ("waiting for customer"); NULL means "leave the status alone".
  belongs_to :info_request_status, :class_name => 'IssueStatus', :optional => true

  DEFAULT_SUBJECT_TEMPLATE = 'Re: [#{{issue.id}}] {{issue.subject}}'.freeze

  # Aktion bei Phishing-Treffer: Links neutralisieren oder Mail in Quarantaene
  PHISHING_ACTIONS = %w[neutralize quarantine].freeze

  # KI-Zusammenfassung: Umfang (nur Erstmail vs. auch Journal-Antworten) und
  # wie der Projekt-Prompt mit dem zentralen Default-Prompt kombiniert wird.
  AI_SCOPES       = %w[initial initial_and_replies].freeze
  AI_PROMPT_MODES = %w[inherit extend override].freeze

  # Wissensbasis (RAG): traegt das Projekt geloeste Tickets bei (off/auto/manual)
  # und wo werden Loesungsvorschlaege angezeigt (off/summary/sidebar/both)?
  KB_INGEST_MODES  = %w[off auto manual].freeze
  KB_DISPLAY_MODES = %w[off summary sidebar both].freeze

  # Vollstaendigkeitspruefung eingehender Erstmails: aus, regelbasiert oder per KI.
  # Die Prompt-Modi teilt sie sich mit der Zusammenfassung (AI_PROMPT_MODES).
  INFO_REQUEST_MODES = RedmineExpertHelpdesk::CompletenessCheck::MODES
  # Sichtbarkeit der Protokoll-Notiz einer Rueckfrage: oeffentlich (Kunde sieht,
  # was erfragt wurde) oder intern (nur Bearbeiter).
  INFO_REQUEST_NOTE_VISIBILITIES = %w[public private].freeze

  validates :phishing_action, :inclusion => { :in => PHISHING_ACTIONS }, :allow_nil => true
  validates :ai_summary_scope, :inclusion => { :in => AI_SCOPES }, :allow_nil => true
  validates :ai_prompt_mode,   :inclusion => { :in => AI_PROMPT_MODES }, :allow_nil => true
  validates :kb_ingest_mode,      :inclusion => { :in => KB_INGEST_MODES }, :allow_nil => true
  validates :kb_proposal_display, :inclusion => { :in => KB_DISPLAY_MODES }, :allow_nil => true
  validates :info_request_mode, :inclusion => { :in => INFO_REQUEST_MODES }, :allow_nil => true
  validates :info_request_note_visibility,
            :inclusion => { :in => INFO_REQUEST_NOTE_VISIBILITIES }, :allow_nil => true
  validates :info_request_ai_prompt_mode,
            :inclusion => { :in => AI_PROMPT_MODES }, :allow_nil => true
  validates :info_request_min_attachment_kb,
            :numericality => { :only_integer => true, :greater_than_or_equal_to => 0 },
            :allow_nil => true
  validates :info_request_min_chars, :info_request_min_words, :info_request_threshold,
            :numericality => { :only_integer => true, :greater_than_or_equal_to => 0 },
            :allow_nil => true
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

  # Configured default assignee, but only if it is still assignable in the
  # project - membership, role or the global group-assignment switch may have
  # changed since the setting was saved. A stale id simply resolves to nil.
  def default_assignee
    return nil if default_assigned_to_id.blank?

    project&.assignable_users&.detect { |p| p.id == default_assigned_to_id }
  end

  # KI-Zusammenfassung auch fuer Journal-Antworten (nicht nur die Erstmail)?
  def ai_summary_for_replies?
    ai_summary_scope == 'initial_and_replies'
  end

  # --- Wissensbasis (RAG) ---
  def kb_ingest_auto?
    kb_ingest_mode == 'auto'
  end

  def kb_ingest_manual?
    kb_ingest_mode == 'manual'
  end

  def kb_show_in_summary?
    %w[summary both].include?(kb_proposal_display.to_s)
  end

  def kb_show_in_sidebar?
    %w[sidebar both].include?(kb_proposal_display.to_s)
  end

  # --- Vollstaendigkeitspruefung / Rueckfrage ---

  # Laeuft die Pruefung in diesem Projekt ueberhaupt? Der globale Schalter wird
  # bewusst NICHT hier geprueft, sondern im Job (eine Gate-Kette, eine Logzeile).
  def info_request_enabled?
    info_request_mode.to_s.present? && info_request_mode != 'off'
  end

  # KI-Modus? Dann braucht der Job zusaetzlich die globalen KI-Schalter.
  def info_request_ai_mode?
    info_request_mode == 'ai'
  end

  # Wird die Rueckfrage als interne Notiz protokolliert? Default ist oeffentlich,
  # damit Bearbeiter und Kunde dieselbe Information vor sich haben.
  def info_request_note_private?
    info_request_note_visibility.to_s == 'private'
  end

  def info_request_keyword_list
    RedmineExpertHelpdesk::CompletenessCheck.keyword_list(self)
  end

  # Betreff/Text der Rueckfrage: Projekt schlaegt zentralen Default (Plugin-
  # Einstellung), damit ein Projekt eigene Formulierungen nutzen kann.
  def effective_info_request_subject
    info_request_subject.presence ||
      Setting.plugin_redmine_expert_helpdesk['info_request_subject'].to_s
  end

  def effective_info_request_body
    info_request_body.presence ||
      Setting.plugin_redmine_expert_helpdesk['info_request_body'].to_s
  end

  # Wie effective_ai_prompt, aber fuer den Pruef-Prompt der Rueckfrage.
  def effective_info_request_prompt
    combine_prompts(
      Setting.plugin_redmine_expert_helpdesk['info_request_ai_prompt'].to_s,
      info_request_ai_prompt.to_s,
      info_request_ai_prompt_mode
    )
  end

  # Effektiver Prompt: erben (zentraler Default), erweitern (zentral + Projekt)
  # oder ersetzen (nur Projekt). Analog zu HelpdeskMailbox#effective_footer_template.
  def effective_ai_prompt
    combine_prompts(
      Setting.plugin_redmine_expert_helpdesk['ai_prompt'].to_s,
      ai_prompt.to_s,
      ai_prompt_mode
    )
  end

  private

  # Gemeinsame Kombinationslogik der Prompt-Modi (inherit/extend/override).
  def combine_prompts(global, project, mode)
    case mode.presence || 'inherit'
    when 'override'
      project.presence || global
    when 'extend'
      [global.presence, project.presence].compact.join("\n\n")
    else # inherit
      global.presence || project
    end
  end
end
