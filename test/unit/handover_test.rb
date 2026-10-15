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
    User.current = @agent
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @settings_before
    User.current = nil
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

  # The target list costs a fixed number of queries, not one per project.
  def test_targets_do_not_look_up_settings_per_project
    [3, 5, 6].each do |pid|
      HelpdeskMailbox.create!(:project => Project.find(pid), :mailbox_address => "hd-#{pid}@expert.local",
                              :provider => 'imap', :imap_host => 'mail.example.com')
    end
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('helpdesk_project_settings') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { Handover.targets_for(@project_a) }

    assert_operator queries.size, :<=, 2, queries.join("\n")
  end

  # A failing relation takes the ticket back with it - nothing is left that
  # the caller could not undo.
  def test_failing_relation_leaves_no_ticket
    RedmineExpertHelpdesk::ThreadScope.stubs(:relate).raises(ActiveRecord::StatementInvalid, 'boom')
    before = Issue.where(:project_id => @project_b.id).count

    assert_raises(ActiveRecord::StatementInvalid) { hand_over('note') }
    assert_equal before, Issue.where(:project_id => @project_b.id).count
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

  # Image references in the copied text move to the copies.
  def test_history_mode_points_image_references_at_the_copies
    image = attach(@source, 'shot.txt')
    @source.update_column(:description, "Bild: !/attachments/download/#{image.id}/shot.txt!")
    issue = hand_over('history')
    copy  = issue.attachments.detect { |a| a.filename == 'shot.txt' }

    assert_includes issue.reload.description, "/attachments/download/#{copy.id}/shot.txt"
    assert_not_includes issue.description, "/attachments/download/#{image.id}/"
  end

  # Creating the ticket mails nobody (Redmine still calls the mailer, the
  # deliveries are switched off); notify does, once the hand-over is final.
  def test_notification_waits_for_notify
    issue = nil
    with_settings :notified_events => ['issue_added'] do
      ActionMailer::Base.deliveries.clear
      issue = hand_over('note')
      assert_empty ActionMailer::Base.deliveries

      Mailer.expects(:deliver_issue_add).with(issue).once
      Handover.notify(issue, @target)
    end
  end

  def test_notify_respects_suppressed_notifications
    issue = hand_over('note')
    @target.update_column(:suppress_notifications, true)
    with_settings :notified_events => ['issue_added'] do
      Mailer.expects(:deliver_issue_add).never
      Handover.notify(issue, @target.reload)
    end
  end

  # Moved on from B, the handed-over ticket still belongs to B's mailbox: a
  # reply through it keeps its thread markers.
  def test_moved_handover_ticket_stays_local_to_the_target_mailbox
    issue = hand_over('note')
    issue.update_column(:project_id, 3)

    assert RedmineExpertHelpdesk::ThreadScope.new(@project_b).local?(issue.reload)
    assert_not RedmineExpertHelpdesk::ThreadScope.new(@project_a).local?(issue)
  end

  # Only projects the agent can see are offered; the others' addresses never
  # reach the form.
  def test_targets_only_list_projects_the_user_can_see
    assert_includes Handover.targets_for(@project_a, @agent).keys, 'helpdesk-b@expert.local'
    assert_empty Handover.targets_for(@project_a, User.anonymous), 'project 2 is private'
  end

  # Without a helpdesk default, Redmine's project default takes the ticket.
  def test_redmine_project_default_assignee_is_the_fallback
    assignee = @project_b.assignable_users.first
    assert assignee, 'fixture project 2 needs an assignable user'
    @project_b.update_column(:default_assigned_to_id, assignee.id)

    assert_equal assignee, hand_over('note').assigned_to
  end

  # Only this Redmine's attachment paths are remapped, not other sites' URLs.
  def test_external_attachment_urls_are_left_alone
    image = attach(@source, 'shot.txt')
    external = "https://vendor.example/attachments/download/#{image.id}/manual.pdf"
    @source.update_column(:description, "Bild: !/attachments/download/#{image.id}/shot.txt! Handbuch: #{external}")
    issue = hand_over('history')
    copy  = issue.attachments.detect { |a| a.filename == 'shot.txt' }

    assert_includes issue.reload.description, "/attachments/download/#{copy.id}/shot.txt"
    assert_includes issue.description, external
  end

  # A sub-path install: InlineImages writes /redmine/attachments/..., which
  # is local too; another site's URL with the same path still is not.
  def test_relative_url_root_paths_are_remapped
    Redmine::Utils.stubs(:relative_url_root).returns('/redmine')
    image = attach(@source, 'shot.txt')
    external = "https://vendor.example/redmine/attachments/download/#{image.id}/manual.pdf"
    @source.update_column(:description,
                          "Bild: !/redmine/attachments/download/#{image.id}/shot.txt! Handbuch: #{external}")
    issue = hand_over('history')
    copy  = issue.attachments.detect { |a| a.filename == 'shot.txt' }

    assert_includes issue.reload.description, "/redmine/attachments/download/#{copy.id}/shot.txt"
    assert_includes issue.description, external
  end

  # A contact's history hides tickets the viewer may not see - a handed-over
  # ticket sits in project 2, which is private.
  def test_contact_history_respects_visibility
    issue   = hand_over('note')
    contact = HelpdeskContact.find_by(:project_id => @project_b.id, :email => 'kunde@example.com')

    assert_includes contact.issues(User.find(1)).to_a, issue
    assert_not_includes contact.issues(User.anonymous).to_a, issue
  end

  def test_unknown_mode_is_rejected
    assert_raises(Handover::Error) { hand_over('everything') }
  end
end
