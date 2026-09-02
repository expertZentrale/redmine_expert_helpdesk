require File.expand_path('../../test_helper', __FILE__)

# Tests for the gate chain of the completeness check. The expensive part is not
# the evaluation but the sending: none of these constellations may trigger a mail
# to a customer.
class HelpdeskCompletenessJobTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :issue_statuses, :users, :trackers,
           :enumerations, :roles, :members, :member_roles

  def setup
    @issue = Issue.find(1)
    @ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => @issue.project_id)
    @ps.info_request_mode = 'heuristic'
    @ps.info_request_min_chars = 100
    @ps.info_request_min_words = 0
    @ps.info_request_threshold = 1
    @ps.save!
    # Short description -> the rule would fire if the job ran.
    @issue.update_columns(:description => 'kaputt')
  end

  def enable_globally(flag = '1')
    Setting.stubs(:plugin_redmine_expert_helpdesk)
           .returns({ 'info_request_enabled' => flag })
  end

  def mailbox
    @mailbox ||= HelpdeskMailbox.create!(:project_id => @issue.project_id,
                                         :mailbox_address => 'hd-claim@example.com')
  end

  def link_contact!
    contact = HelpdeskContact.create!(:project_id => @issue.project_id,
                                      :email => 'kunde@example.com', :name => 'Kunde')
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => contact.id)
  end

  def test_skips_when_globally_disabled
    enable_globally('0')
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    Issue.expects(:find_by).never
    assert_nothing_raised { HelpdeskCompletenessJob.perform_now(@issue.id) }
  end

  def test_skips_when_project_mode_is_off
    enable_globally
    @ps.update!(:info_request_mode => 'off')
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  # Without a linked contact/mailbox there is nobody to write to.
  def test_skips_without_contact
    enable_globally
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  # Repeat guard: a follow-up that already went out is not repeated.
  def test_repeat_guard_blocks_second_run
    enable_globally
    info = link_contact!
    info.update!(:helpdesk_mailbox_id => nil, :info_request_count => 1)
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  def test_ai_mode_without_global_ai_sends_nothing
    enable_globally
    @ps.update!(:info_request_mode => 'ai')
    link_contact!
    RedmineExpertHelpdesk::AiFeatures.stubs(:ai_enabled?).returns(false)
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  # --- The claim is the atomic repeat guard ---

  def test_claim_succeeds_once_then_refuses
    info = link_contact!
    assert HelpdeskTicketInfo.claim_info_request!(@issue), 'first claim must succeed'
    assert_not HelpdeskTicketInfo.claim_info_request!(@issue), 'second claim must be refused'
    assert_equal 1, info.reload.info_request_count
  end

  def test_force_bypasses_the_claim
    info = link_contact!
    assert HelpdeskTicketInfo.claim_info_request!(@issue)
    assert HelpdeskTicketInfo.claim_info_request!(@issue, :force => true)
    assert_equal 2, info.reload.info_request_count
  end

  def test_claim_records_the_timestamp
    info = link_contact!
    HelpdeskTicketInfo.claim_info_request!(@issue)
    assert_not_nil info.reload.info_request_sent_at
  end

  # Without a linked row there is nothing to claim - and nothing to send.
  def test_claim_without_ticket_info_is_refused
    assert_not HelpdeskTicketInfo.claim_info_request!(@issue)
  end

  # A failed send must not release the claim: at-most-once beats at-least-once here.
  def test_failed_send_keeps_the_claim
    enable_globally
    info = link_contact!
    info.update!(:helpdesk_mailbox_id => mailbox.id)
    RedmineExpertHelpdesk::InfoRequestMailer
      .stubs(:deliver!).raises(StandardError, 'SMTP down')

    assert_nothing_raised { HelpdeskCompletenessJob.perform_now(@issue.id) }
    assert_equal 1, info.reload.info_request_count,
                 'the claim must survive a failed send'
  end

  # And the ticket stays claimed, so a retry does not mail the customer after all.
  def test_retry_after_a_failed_send_does_not_mail
    enable_globally
    info = link_contact!
    info.update!(:helpdesk_mailbox_id => mailbox.id)
    RedmineExpertHelpdesk::InfoRequestMailer
      .stubs(:deliver!).raises(StandardError, 'SMTP down')
    HelpdeskCompletenessJob.perform_now(@issue.id)

    RedmineExpertHelpdesk::InfoRequestMailer.unstub(:deliver!)
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  # --- apply_status must never write a dangling status ---

  def apply_status(status_id)
    @ps.update_columns(:info_request_status_id => status_id)
    issue = Issue.find(@issue.id)
    before = issue.status_id
    HelpdeskCompletenessJob.new.send(:apply_status, issue, @ps.reload)
    [before, Issue.find(@issue.id).status_id]
  end

  # 0 is not blank in Rails, so it has to be rejected explicitly.
  def test_zero_status_is_not_written
    before, after = apply_status(0)
    assert_equal before, after
  end

  # The status may have been deleted long after it was configured.
  def test_deleted_status_is_not_written
    before, after = apply_status(999_999)
    assert_equal before, after
  end

  def test_valid_status_is_written
    target = IssueStatus.where(:is_closed => false).where.not(:id => @issue.status_id).first
    _before, after = apply_status(target.id)
    assert_equal target.id, after
  end

  # Defence in depth: a status can be flagged as closed after it was configured.
  def test_closed_status_is_not_written
    closed = IssueStatus.where(:is_closed => true).first
    before, after = apply_status(closed.id)
    assert_equal before, after
  end

  # The job must never raise - mail processing is already finished by then.
  def test_never_raises
    enable_globally
    assert_nothing_raised { HelpdeskCompletenessJob.perform_now(-1) }
  end

  def test_unknown_issue_is_silent
    enable_globally
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(999_999)
  end
end
