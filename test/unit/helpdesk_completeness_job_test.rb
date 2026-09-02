require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Gate-Kette der Vollstaendigkeitspruefung. Der teure Teil ist
# nicht die Auswertung, sondern der Versand: keine dieser Konstellationen darf
# eine Mail an einen Kunden ausloesen.
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
    # Kurze Beschreibung -> die Regel wuerde greifen, wenn der Job laeuft.
    @issue.update_columns(:description => 'kaputt')
  end

  def enable_globally(flag = '1')
    Setting.stubs(:plugin_redmine_expert_helpdesk)
           .returns({ 'info_request_enabled' => flag })
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

  # Ohne verknuepften Kontakt/Postfach gibt es niemanden zum Anschreiben.
  def test_skips_without_contact
    enable_globally
    RedmineExpertHelpdesk::InfoRequestMailer.expects(:deliver!).never
    HelpdeskCompletenessJob.perform_now(@issue.id)
  end

  # Wiederholungssperre: eine bereits gestellte Rueckfrage wird nicht wiederholt.
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

  # Der Job darf niemals werfen - die Mailverarbeitung ist da schon abgeschlossen.
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
