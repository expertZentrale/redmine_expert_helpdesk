# Delivers text for the ticket's note field: quotes (original mail, complete
# conversation, mail conversation), expanded answer templates and the AI answer
# draft.
#
# Always answers with JSON; the insertion is done by the toolbar of the edit
# form (helpdesk/_note_toolbar). JSON rather than a .js.erb, because Redmine 7
# runs script responses through @rails/request.js and Redmine 5.1 through
# jQuery UJS — a fetch() returning JSON behaves identically on both.
class HelpdeskNoteContentController < ApplicationController
  before_action :find_issue
  before_action :authorize_note_content

  SOURCES = %w[description conversation mail_conversation template answer_draft].freeze

  # answer_draft is the only source that spends money, talks to the network and
  # can take seconds, so it carries its own gate chain, its own throttle and its
  # own rescues below. Everything else here is string concatenation.
  #
  # The lease has to outlive the whole operation, not just the chat call:
  # embedding and the vector-store query happen first, and ai_answer_timeout is
  # configurable up to 45 s. A lease that expires mid-request would let a second
  # paid draft through for the same ticket.
  DRAFT_LOCK_MARGIN = 15

  def create
    source = params[:source].to_s
    unless SOURCES.include?(source)
      return render_error(l(:error_helpdesk_note_content_unknown_source))
    end

    result =
      case source
      when 'description'       then RedmineExpertHelpdesk::NoteQuoter.description(@issue)
      when 'conversation'      then RedmineExpertHelpdesk::NoteQuoter.conversation(@issue)
      when 'mail_conversation' then RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true)
      when 'answer_draft'      then answer_draft_result
      else                          template_result
      end
    return if performed?

    if result.content.blank?
      return render_error(l(:error_helpdesk_note_content_empty))
    end

    render :json => { :content   => result.content,
                      :truncated => result.truncated?,
                      :omitted   => result.omitted.to_i,
                      :sources   => draft_sources(result) }
  end

  private

  # The AI answer draft. Reads as a wall of guards on purpose: this is the one
  # endpoint whose output is proposed to a customer, so every reason not to
  # produce one is spelled out and gets its own message.
  def answer_draft_result
    contact = HelpdeskTicketInfo.for_issue(@issue)&.helpdesk_contact
    if contact.nil?
      render_error(l(:error_helpdesk_ai_answer_no_contact))
      return nil
    end
    unless RedmineExpertHelpdesk::AnswerDrafter.available_for?(@project, contact)
      render_error(l(:error_helpdesk_ai_answer_unavailable))
      return nil
    end

    return nil unless claim_draft_slot

    begin
      RedmineExpertHelpdesk::AnswerDrafter.new.draft(
        @issue, :contact => contact,
        :variant => params[:variant], :user => User.current
      )
    rescue RedmineExpertHelpdesk::AnswerDrafter::KbUnavailableError
      render_error(l(:error_helpdesk_ai_answer_kb_unavailable))
      nil
    rescue RedmineExpertHelpdesk::AnswerDrafter::NoGroundingError => e
      render_error(no_grounding_message(e))
      nil
    rescue RedmineExpertHelpdesk::KnowledgeStore::StoreError => e
      log_draft_failure(e)
      render_error(l(:error_helpdesk_ai_answer_store_unreachable), :bad_gateway)
      nil
    rescue RedmineExpertHelpdesk::AiClient::TransportError => e
      log_draft_failure(e)
      render_error(l(:error_helpdesk_ai_answer_timeout), :gateway_timeout)
      nil
    rescue RedmineExpertHelpdesk::AiClient::AiError => e
      log_draft_failure(e)
      render_error(*ai_error_response(e))
      nil
    rescue StandardError => e
      log_draft_failure(e)
      render_error(l(:error_helpdesk_ai_answer_failed), :internal_server_error)
      nil
    ensure
      release_draft_slot
    end
  end

  # A near miss and a blank are different situations for the agent: at 61 % the
  # threshold is arguably too high, at 12 % the case is genuinely new and worth
  # writing by hand. Percentages only - no titles, no ticket numbers.
  def no_grounding_message(error)
    best = error.respond_to?(:best_score) ? error.best_score : nil
    return l(:error_helpdesk_ai_answer_no_grounding) if best.nil?

    l(:error_helpdesk_ai_answer_no_grounding_score,
      :best => (best.to_f * 100).round, :needed => (error.threshold.to_f * 100).round)
  end

  # One draft at a time per user, and not twice in a row on the same ticket.
  # The JS busy flag only covers a single page: two tabs, or reload-then-click,
  # both get through, and a hanging provider would otherwise pin one Puma thread
  # per click. Redmine's default pool is five.
  def claim_draft_slot
    @draft_lock_token = SecureRandom.hex(8)
    @draft_lock_keys  = ["hd:ai_draft:u#{User.current.id}", "hd:ai_draft:i#{@issue.id}"]
    ttl = draft_lock_seconds
    taken = []
    @draft_lock_keys.each do |key|
      unless Rails.cache.write(key, @draft_lock_token, :expires_in => ttl, :unless_exist => true)
        taken.each { |k| release_key(k) }
        @draft_lock_keys = []
        render_error(l(:error_helpdesk_ai_answer_busy), :too_many_requests)
        return false
      end
      taken << key
    end
    true
  rescue StandardError
    # A broken cache must not block the feature - it only weakens the throttle.
    @draft_lock_keys = []
    true
  end

  # Whole-operation budget: embedding, the vector store, the reranker, then the
  # model. The rerank term is counted even when reranking is off, like the other
  # two are counted regardless of backend: this bounds a lock, and a lock that
  # expires mid-draft costs more than a few seconds of slack on a ~48 s ceiling.
  def draft_lock_seconds
    settings = Setting.plugin_redmine_expert_helpdesk
    chat     = settings['ai_answer_timeout'].to_i
    chat     = 20 unless chat.positive?
    chat.clamp(5, 45) +
      RedmineExpertHelpdesk::AnswerDrafter::EMBED_TIMEOUT +
      RedmineExpertHelpdesk::AnswerDrafter::STORE_READ_TIMEOUT +
      RedmineExpertHelpdesk::AnswerDrafter::RERANK_TIMEOUT +
      DRAFT_LOCK_MARGIN
  end

  def release_draft_slot
    Array(@draft_lock_keys).each { |key| release_key(key) }
  rescue StandardError
    nil
  end

  # Only ever drop our own lease. If ours already expired and somebody else took
  # the key, deleting it unconditionally would hand a third request a free pass.
  def release_key(key)
    Rails.cache.delete(key) if Rails.cache.read(key) == @draft_lock_token
  rescue StandardError
    nil
  end

  # A timeout is a different thing from a rejected request, and the agent can act
  # on the difference: retry now, or go and look at the settings.
  def ai_error_response(error)
    case error.status
    when 429      then [l(:error_helpdesk_ai_answer_rate_limited), :too_many_requests]
    when 500..599 then [l(:error_helpdesk_ai_answer_provider_down), :bad_gateway]
    else               [l(:error_helpdesk_ai_answer_failed), :unprocessable_entity]
    end
  end

  # The provider's body carries endpoints, org ids and sometimes fragments of the
  # prompt: it belongs in the log, never in the response. Same treatment as
  # HelpdeskAiSummaryJob gives it.
  def log_draft_failure(error)
    body = error.respond_to?(:body) ? error.body.to_s[0, 500] : nil
    Rails.logger.warn("[helpdesk][ai] Antwortentwurf fehlgeschlagen (Issue ##{@issue.id}): " \
                      "#{error.class}: #{error.message}#{body.present? ? " | #{body}" : ''}")
  end

  # Which knowledge-base tickets grounded the draft. Shown to the agent in the
  # toolbar status line only - these numbers must never reach the note field,
  # which is the body of the outgoing mail.
  def draft_sources(result)
    return [] unless result.respond_to?(:sources)

    Array(result.sources).filter_map do |src|
      issue = Issue.visible.find_by(:id => src[:issue_id])
      next if issue.nil?

      { :issue_id => issue.id, :score => src[:score],
        :url => issue_path(issue), :subject => issue.subject }
    end
  end

  def template_result
    template = HelpdeskReplyTemplate.active.available_for(@project).find_by(:id => params[:template_id])
    if template.nil?
      render_error(l(:error_helpdesk_reply_template_not_found), :not_found)
      return nil
    end

    contact = HelpdeskTicketInfo.for_issue(@issue)&.helpdesk_contact
    RedmineExpertHelpdesk::NoteQuoter::Result.new(
      template.render_for(@issue, contact, User.current), 0
    )
  end

  # Errors are rendered here rather than via render_404/deny_access on purpose:
  # their envelope differs between the supported Redmine versions (Redmine 7
  # wraps them into a 422 response for JSON). The toolbar needs dependable
  # status codes and a flat { "error": "..." }.
  def render_error(message, status = :unprocessable_entity)
    render :json => { :error => message }, :status => status
  end

  # Issue.visible rather than Issue.find: this endpoint hands out journal text,
  # so visibility has to apply at load time, not only through the permission.
  def find_issue
    @issue = Issue.visible.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_error(l(:notice_file_not_found), :not_found)
  end

  # send_helpdesk_reply as for the reply form: the text exists to compose a
  # customer reply. view_helpdesk_info would be a :read permission that
  # non-members hold in public projects too.
  def authorize_note_content
    return render_error(l(:notice_file_not_found), :not_found) unless @project.module_enabled?(:helpdesk)
    return if User.current.allowed_to?(:send_helpdesk_reply, @project)

    render_error(l(:notice_not_authorized), :forbidden)
  end
end
