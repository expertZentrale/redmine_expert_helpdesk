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

  def hand_over(mode, attachments: [], note: 'Bitte uebernehmen', bcc: false)
    Handover.new(:source => @source, :mailbox => @target, :user => @agent, :mode => mode,
                 :note => note, :attachments => attachments, :contact => @contact, :bcc => bcc).call
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

  # Reached by Bcc only: a relation would show the source ticket's readers
  # who else got the topic.
  def test_bcc_only_target_gets_no_relation
    issue = hand_over('note', :bcc => true)

    assert_not IssueRelation.where(:issue_from_id => [issue.id, @source.id],
                                   :issue_to_id => [issue.id, @source.id]).exists?
    assert_equal 'kunde@example.com', HelpdeskTicketInfo.for_issue(issue).helpdesk_contact.email
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

  # A note a model wrote stays marked on the target: visible as a note of its
  # own, kept out of what the knowledge base and answer drafts read.
  def test_history_mode_keeps_ai_drafted_notes_marked
    drafted = Journal.create!(:journalized => @source, :user => @agent, :notes => 'Vorschlag der KI')
    HelpdeskAiDraftedJournal.create!(:journal_id => drafted.id, :issue_id => @source.id, :user_id => @agent.id)
    Journal.create!(:journalized => @source, :user => @agent, :notes => 'Eigene Notiz')
    issue = hand_over('history')

    assert_not_includes issue.description, 'Vorschlag der KI'
    assert_includes issue.description, I18n.t(:text_helpdesk_handover_ai_drafted)
    assert_includes issue.description, '> Eigene Notiz'
    note = issue.journals.detect { |j| j.notes.to_s.include?('Vorschlag der KI') }
    assert note, 'the drafted text is still there, as a note'
    assert_includes HelpdeskAiDraftedJournal.journal_ids_for(issue.id), note.id
    text = RedmineExpertHelpdesk::KnowledgeExtractor.ticket_text(issue)
    assert_not_includes text, 'Vorschlag der KI'
    assert_includes text, 'Eigene Notiz'
  end

  # Images in a drafted note move to the copies too, in both modes.
  def test_ai_drafted_notes_point_images_at_the_copies
    image = attach(@source, 'shot.txt')
    ref   = "!/attachments/download/#{image.id}/shot.txt!"
    drafted = Journal.create!(:journalized => @source, :user => @agent, :notes => "Alt #{ref}")
    HelpdeskAiDraftedJournal.create!(:journal_id => drafted.id, :issue_id => @source.id, :user_id => @agent.id)

    [['history', 'Alt'], ['note', 'Neu']].each do |mode, marker|
      issue = Handover.new(:source => @source, :mailbox => @target, :user => @agent, :mode => mode,
                           :note => "Neu #{ref}", :attachments => [image], :contact => @contact,
                           :ai_drafted => true).call
      copy = issue.attachments.detect { |a| a.filename == 'shot.txt' }
      note = issue.journals.detect { |j| j.notes.to_s.include?(marker) }

      assert_includes note.notes, "/attachments/download/#{copy.id}/shot.txt", mode
      assert_not_includes note.notes, "/attachments/download/#{image.id}/", mode
    end
  end

  def test_ai_drafted_note_goes_over_marked
    issue = Handover.new(:source => @source, :mailbox => @target, :user => @agent, :mode => 'note',
                         :note => 'Entwurf aus der KI', :contact => @contact, :ai_drafted => true).call

    assert_not_includes issue.description, 'Entwurf aus der KI'
    note = issue.journals.detect { |j| j.notes == 'Entwurf aus der KI' }
    assert note
    assert_includes HelpdeskAiDraftedJournal.journal_ids_for(issue.id), note.id
    assert_not_includes RedmineExpertHelpdesk::KnowledgeExtractor.ticket_text(issue), 'Entwurf aus der KI'
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

  # Creating the ticket does not even reach the mailer - nothing to enqueue,
  # and no process-wide switch that other requests' mail would run into.
  # Finalizing notifies, once the hand-over is final.
  def test_notification_waits_for_finalize
    with_settings :notified_events => ['issue_added'] do
      Mailer.expects(:deliver_issue_add).never
      issue = hand_over('note')
      assert ActionMailer::Base.perform_deliveries, 'deliveries stay on for everybody else'

      Mailer.unstub(:deliver_issue_add)
      Mailer.expects(:deliver_issue_add).with(issue).once
      Handover.finalize(issue, @target)
    end
  end

  # A closed default status would put the provisional ticket into the
  # knowledge base, where it outlives a hand-over that is taken back.
  def test_knowledge_base_waits_for_finalize
    closed = IssueStatus.where(:is_closed => true).first
    @target.update_column(:default_status_id, closed.id)
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_enabled?).returns(true)
    HelpdeskProjectSetting.for_project(@project_b).update_column(:kb_ingest_mode, 'auto')

    HelpdeskKnowledgeIngestJob.expects(:perform_later).never
    issue = hand_over('note')
    assert issue.closed?

    HelpdeskKnowledgeIngestJob.unstub(:perform_later)
    HelpdeskKnowledgeIngestJob.expects(:perform_later).with(issue.id).once
    Handover.finalize(issue, @target.reload)
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

  # --- taking a hand-over back ----------------------------------------------

  def test_undo_removes_an_untouched_ticket
    issue = hand_over('note')

    assert Handover.undo(issue)
    assert_not Issue.exists?(issue.id)
  end

  # Visible in the target project the moment it is committed: someone there
  # may already have answered, and deleting would take that with it.
  def test_undo_keeps_a_ticket_someone_worked_on
    issue = hand_over('note')
    other = Issue.find(issue.id)
    other.init_journal(User.find(3), 'Schon dran')
    assert other.save(:validate => false)

    assert_not Handover.undo(issue)
    assert Issue.exists?(issue.id)
  end

  # Work saved right as the creation commits - before Handover#call has
  # returned - is someone's work, not part of the untouched baseline.
  # Redmine's own after_create_commit callback stands in for that request.
  def test_undo_baseline_is_taken_before_the_commit
    project_b = @project_b
    Issue.any_instance.stubs(:add_auto_watcher).with do
      ticket = Issue.where(:project_id => project_b.id).order(:id).last
      ticket.init_journal(User.find(3), 'Gleich nach dem Commit')
      ticket.save(:validate => false)
      true
    end
    issue = hand_over('note')

    assert_includes issue.journals.reload.map(&:notes), 'Gleich nach dem Commit', 'the stand-in did not run'
    assert_not Handover.undo(issue)
    assert Issue.exists?(issue.id)
  end

  def test_undo_keeps_a_ticket_with_booked_time
    issue = hand_over('note')
    # Without validation: who may log time where is not under test.
    TimeEntry.new(:project => @project_b, :issue => issue, :user => @agent, :author => @agent, :hours => 1,
                  :spent_on => Date.today, :activity => TimeEntryActivity.first).save(:validate => false)

    assert_not Handover.undo(issue)
    assert Issue.exists?(issue.id)
  end

  def test_unknown_mode_is_rejected
    assert_raises(Handover::Error) { hand_over('everything') }
  end
end
