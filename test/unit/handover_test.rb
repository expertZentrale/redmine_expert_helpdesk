require File.expand_path('../../test_helper', __FILE__)

# Experimental hand-over of a ticket to another project without a mail.
# Fixtures: issue 1 lives in project 1, the target mailbox in project 2.
class HandoverTest < ActiveSupport::TestCase
  fixtures :all

  Handover = RedmineExpertHelpdesk::Handover

  def setup
    set_tmp_attachments_directory
    @settings_before = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('handover_enabled' => '1')
    Setting.cross_project_issue_relations = '1'

    @source  = Issue.find(1)
    @agent   = User.find(2)
    @project_a = @source.project
    @project_b = Project.find(2)
    [@project_a, @project_b].each do |p|
      p.enable_module!(:helpdesk)
      HelpdeskProjectSetting.for_project(p).tap { |s| s.handover_enabled = true }.save!
    end
    @target = HelpdeskMailbox.create!(:project => @project_b, :mailbox_address => 'helpdesk-b@expert.local',
                                      :provider => 'imap', :imap_host => 'mail.example.com')
    @contact = HelpdeskContact.create!(:project => @project_a, :email => 'kunde@example.com', :name => 'Kunde')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @settings_before
  end

  def hand_over(mode, attachments: [], note: 'Bitte uebernehmen')
    Handover.new(:source => @source, :mailbox => @target, :user => @agent, :mode => mode,
                 :note => note, :attachments => attachments, :contact => @contact).call
  end

  def attach(issue, name)
    Attachment.create!(:container => issue, :author => @agent,
                       :file => uploaded_test_file('testfile.txt', 'text/plain'), :filename => name)
  end

  # --- switches -----------------------------------------------------------

  def test_targets_need_the_central_switch
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('handover_enabled' => '0')

    assert_empty Handover.targets_for(@project_a)
  end

  def test_targets_need_the_source_project_to_take_part
    HelpdeskProjectSetting.for_project(@project_a).update!(:handover_enabled => false)

    assert_empty Handover.targets_for(@project_a)
  end

  def test_targets_need_the_target_project_to_take_part
    HelpdeskProjectSetting.for_project(@project_b).update!(:handover_enabled => false)

    assert_empty Handover.targets_for(@project_a)
  end

  def test_targets_list_other_projects_only
    HelpdeskMailbox.create!(:project => @project_a, :mailbox_address => 'helpdesk-a@expert.local',
                            :provider => 'imap', :imap_host => 'mail.example.com')

    assert_equal ['helpdesk-b@expert.local'], Handover.targets_for(@project_a).keys
  end

  def test_split_takes_target_addresses_out_and_keeps_the_rest
    targets = Handover.targets_for(@project_a)
    kept, hits = Handover.split('kunde@example.com, "Team B" <Helpdesk-B@expert.local>', targets)

    assert_equal 'kunde@example.com', kept
    assert_equal [@target], hits
  end

  # --- note mode ------------------------------------------------------------

  def test_note_mode_creates_a_ticket_in_the_target_project
    @source.update_column(:description, 'Urspruengliche Beschreibung')
    issue = hand_over('note')

    assert_equal @project_b, issue.project
    assert_equal @source.subject, issue.subject
    assert_equal @agent, issue.author
    assert_includes issue.description, 'Bitte uebernehmen'
    assert_includes issue.description, "##{@source.id}"
    assert_not_includes issue.description, 'Urspruengliche Beschreibung', 'note mode carries no history'
  end

  def test_note_mode_copies_only_the_given_attachments
    sent  = attach(@source, 'sent.txt')
    _left = attach(@source, 'left-behind.txt')
    issue = hand_over('note', :attachments => [sent])

    assert_equal ['sent.txt'], issue.attachments.map(&:filename)
    assert_equal sent.diskfile, issue.attachments.first.diskfile, 'copies share the stored file'
  end

  def test_relation_and_contact
    issue = hand_over('note')

    assert IssueRelation.where(:issue_from_id => [issue.id, @source.id], :issue_to_id => [issue.id, @source.id]).exists?
    info = HelpdeskTicketInfo.for_issue(issue)
    assert_equal 'kunde@example.com', info.helpdesk_contact.email
    assert_equal @project_b.id, info.helpdesk_contact.project_id, 'the target project gets its own contact'
    assert_equal @target, info.helpdesk_mailbox
  end

  # --- history mode -----------------------------------------------------------

  def test_history_mode_carries_description_and_public_notes_only
    @source.update_column(:description, 'Urspruengliche Beschreibung')
    Journal.create!(:journalized => @source, :user => @agent, :notes => 'Oeffentliche Notiz')
    Journal.create!(:journalized => @source, :user => @agent, :notes => 'Interne Notiz', :private_notes => true)
    issue = hand_over('history')

    assert_includes issue.description, '> Urspruengliche Beschreibung'
    assert_includes issue.description, '> Oeffentliche Notiz'
    assert_not_includes issue.description, 'Interne Notiz'
    assert issue.description.index('Urspruengliche') < issue.description.index('Oeffentliche'), 'oldest first'
  end

  def test_history_mode_copies_all_attachments
    attach(@source, 'one.txt')
    attach(@source, 'two.txt')
    issue = hand_over('history')

    assert_equal @source.reload.attachments.map(&:filename).sort, issue.attachments.map(&:filename).sort
    assert_includes issue.attachments.map(&:filename), 'two.txt'
  end

  def test_unknown_mode_is_rejected
    assert_raises(Handover::Error) { hand_over('everything') }
  end
end
