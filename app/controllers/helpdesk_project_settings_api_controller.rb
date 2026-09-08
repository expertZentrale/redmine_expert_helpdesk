# REST-API fuer die projektbezogenen Helpdesk-Einstellungen (Singleton je Projekt).
# JSON/XML via .api.rsb. Lesen: view_helpdesk_info oder manage_helpdesk;
# Schreiben: manage_helpdesk. Partielles Update (nur uebergebene Felder).
class HelpdeskProjectSettingsApiController < ApplicationController
  before_action :find_project_by_project_id
  before_action :require_helpdesk_module
  before_action :load_setting
  before_action :authorize_read,  :only => [:show]
  before_action :authorize_write, :only => [:update]
  accept_api_auth :show, :update

  def show
    load_priorities
    respond_to { |format| format.api }
  end

  def update
    hp = params[:helpdesk_project_setting] || {}
    was_enabled = @setting.sla_enabled?

    apply_boolean(:send_reply_by_default, hp)
    apply_boolean(:reply_assign_to_sender, hp)
    apply_boolean(:phishing_check_enabled, hp)
    apply_boolean(:sla_enabled, hp)
    apply_boolean(:sla_notify_enabled, hp)
    apply_boolean(:ai_summary_enabled, hp)
    apply_boolean(:ai_attach_metadata, hp)
    apply_boolean(:ai_attach_text, hp)
    apply_boolean(:ai_attach_images, hp)
    apply_boolean(:ai_include_journal, hp)
    apply_boolean(:ai_include_private_notes, hp)

    @setting.reply_subject_template = hp[:reply_subject_template].to_s if hp.key?(:reply_subject_template)
    @setting.reply_status_id        = hp[:reply_status_id].presence   if hp.key?(:reply_status_id)
    @setting.default_assigned_to_id = hp[:default_assigned_to_id].presence if hp.key?(:default_assigned_to_id)
    @setting.phishing_action        = hp[:phishing_action]            if hp.key?(:phishing_action)
    @setting.sla_reaction_minutes   = hp[:sla_reaction_minutes].presence if hp.key?(:sla_reaction_minutes)
    @setting.sla_solution_minutes   = hp[:sla_solution_minutes].presence if hp.key?(:sla_solution_minutes)
    @setting.sla_work_start         = hp[:sla_work_start]             if hp.key?(:sla_work_start)
    @setting.sla_work_end           = hp[:sla_work_end]              if hp.key?(:sla_work_end)
    @setting.sla_notify_email       = hp[:sla_notify_email].presence  if hp.key?(:sla_notify_email)
    @setting.sla_notify_user_id     = hp[:sla_notify_user_id].presence if hp.key?(:sla_notify_user_id)
    # KI-Zusammenfassung / Wissensbasis: Werte werden im Modell gegen die
    # jeweiligen Enum-Listen validiert (AI_SCOPES, AI_PROMPT_MODES, KB_*).
    @setting.ai_summary_scope       = hp[:ai_summary_scope]           if hp.key?(:ai_summary_scope)
    @setting.ai_prompt_mode         = hp[:ai_prompt_mode]             if hp.key?(:ai_prompt_mode)
    @setting.ai_prompt              = hp[:ai_prompt].to_s             if hp.key?(:ai_prompt)
    @setting.ai_min_image_kb        = hp[:ai_min_image_kb].presence  if hp.key?(:ai_min_image_kb)
    @setting.kb_ingest_mode         = hp[:kb_ingest_mode]             if hp.key?(:kb_ingest_mode)
    @setting.kb_proposal_display    = hp[:kb_proposal_display]        if hp.key?(:kb_proposal_display)
    if hp.key?(:sla_work_days)
      days = Array(hp[:sla_work_days]).flat_map { |d| d.to_s.split(',') }
                                      .map(&:to_i).select { |d| (1..7).cover?(d) }
      @setting.sla_work_days = days.join(',')
    end

    # Aktivierungszeitpunkt merken: SLA gilt nur fuer Tickets ab diesem Datum.
    @setting.sla_enabled_at = Time.current if @setting.sla_enabled? && !was_enabled

    return unless apply_info_request_settings(hp)

    begin
      ActiveRecord::Base.transaction do
        @setting.save!
        update_sla_priorities if params.key?(:sla_priorities)
      end
    rescue ActiveRecord::RecordInvalid => e
      return render_validation_errors(e.record)
    end

    RedmineExpertHelpdesk::Sla.refresh_project_deadlines!(@project)
    load_priorities
    respond_to { |format| format.api { render :action => 'show' } }
  end

  private

  def load_setting
    @setting = HelpdeskProjectSetting.for_project(@project)
  end

  def load_priorities
    @priorities = HelpdeskSlaPriority.where(:project_id => @project.id)
                                     .includes(:priority).order(:priority_id => :asc)
  end

  # Completeness check / follow-up. Partial like the rest: only keys that were
  # sent change anything. Mode, prompt mode, visibility and the numeric floors
  # are validated by the model. Two more rules are enforced here rather than in
  # the model, because the form deliberately coerces them (threshold below 1
  # becomes 1, an unusable status becomes none) while an API caller needs to
  # hear about it: they answer 422.
  def apply_info_request_settings(hp)
    apply_boolean(:info_request_require_attachment, hp)

    %i[info_request_mode info_request_ai_prompt_mode info_request_note_visibility].each do |f|
      @setting.public_send("#{f}=", hp[f].to_s) if hp.key?(f)
    end
    %i[info_request_min_chars info_request_min_words info_request_min_attachment_kb
       info_request_threshold].each do |f|
      @setting.public_send("#{f}=", hp[f].presence) if hp.key?(f)
    end
    %i[info_request_keywords info_request_sender_blacklist info_request_ai_prompt
       info_request_subject info_request_body].each do |f|
      @setting.public_send("#{f}=", hp[f].to_s.strip.presence) if hp.key?(f)
    end

    # A threshold of 0 would fire on a perfect mail; the check is switched off
    # via the mode instead. null is allowed and means the default (1).
    if hp.key?(:info_request_threshold) && !@setting.info_request_threshold.nil? &&
       @setting.info_request_threshold.to_i < 1
      @setting.errors.add(:info_request_threshold, :greater_than_or_equal_to, :count => 1)
    end

    # Existing, OPEN status only: an automatic follow-up must never close a
    # ticket, because every SLA reader treats closed_on as reaction-done and
    # solution-done (see HelpdeskCompletenessJob#apply_status).
    if hp.key?(:info_request_status_id)
      status_id = hp[:info_request_status_id].presence
      if status_id.nil?
        @setting.info_request_status_id = nil
      elsif IssueStatus.where(:id => status_id.to_i, :is_closed => false).exists?
        @setting.info_request_status_id = status_id.to_i
      else
        @setting.errors.add(:info_request_status_id, :inclusion)
      end
    end

    return true if @setting.errors.empty?

    render_validation_errors(@setting)
    false
  end

  def apply_boolean(field, hp)
    return unless hp.key?(field)

    @setting.public_send("#{field}=", ActiveModel::Type::Boolean.new.cast(hp[field]))
  end

  # Prioritaets-Overrides (Array von {priority_id, reaction_minutes, solution_minutes}):
  # beide Zeiten leer -> Override loeschen, sonst anlegen/aktualisieren.
  def update_sla_priorities
    Array(params[:sla_priorities]).each do |row|
      pid = row[:priority_id].to_i
      next if pid <= 0

      reaction = row[:reaction_minutes].presence
      solution = row[:solution_minutes].presence
      override = HelpdeskSlaPriority.find_or_initialize_by(:project_id => @project.id, :priority_id => pid)

      if reaction.nil? && solution.nil?
        override.destroy if override.persisted?
      else
        override.reaction_minutes = reaction
        override.solution_minutes = solution
        override.save!
      end
    end
  end

  def require_helpdesk_module
    render_403 unless @project.module_enabled?(:helpdesk)
  end

  def authorize_read
    unless User.current.allowed_to?(:view_helpdesk_info, @project) ||
           User.current.allowed_to?(:manage_helpdesk, @project)
      deny_access
    end
  end

  def authorize_write
    deny_access unless User.current.allowed_to?(:manage_helpdesk, @project)
  end
end
