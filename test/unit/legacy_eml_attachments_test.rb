require File.expand_path('../../test_helper', __FILE__)

# EML repair (legacy HelpdeskTicket -> issue) and its reverse, per project. Runs
# against the real helpdesk_tickets table, which the test stack gets from
# redmine_contacts_helpdesk; skipped where that plugin is absent.
class LegacyEmlAttachmentsTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :attachments, :users

  Import = RedmineExpertHelpdesk::LegacyContactsImport

  def setup
    skip 'needs the helpdesk_tickets table of redmine_contacts_helpdesk' unless conn.table_exists?('helpdesk_tickets')
    conn.execute('DELETE FROM helpdesk_tickets')
    Attachment.where(:container_type => 'HelpdeskTicket').update_all(:container_type => 'Issue', :container_id => 3)
  end

  def conn
    ActiveRecord::Base.connection
  end

  def ticket!(issue_id)
    conn.insert("INSERT INTO helpdesk_tickets (issue_id, source) VALUES (#{issue_id}, 0)")
    conn.select_value('SELECT MAX(id) FROM helpdesk_tickets').to_i
  end

  # Turns a fixture attachment into a legacy original mail on the given container
  def mail!(attachment_id, container_type, container_id, filename = 'message.eml')
    Attachment.find(attachment_id).tap do |a|
      a.update_columns(:container_type => container_type, :container_id => container_id,
                       :filename => filename, :content_type => 'message/rfc822')
    end
  end

  def test_fix_moves_only_the_selected_projects
    mine  = mail!(1, 'HelpdeskTicket', ticket!(1)) # issue 1, project 1
    other = mail!(4, 'HelpdeskTicket', ticket!(4)) # issue 4, project 2

    result = Import.new(['1']).fix_attachments

    assert_equal 1, result.attachments_fixed
    assert_equal ['Issue', 1], mine.reload.slice(:container_type, :container_id).values
    assert_equal 'HelpdeskTicket', other.reload.container_type, 'unselected project must stay untouched'
  end

  def test_orphans_are_not_counted_as_misplaced
    mail!(1, 'HelpdeskTicket', nil)
    assert_equal 0, Import.misplaced_attachment_count, 'a mail without ticket can never be repaired'

    mail!(4, 'HelpdeskTicket', ticket!(1))
    assert_equal 1, Import.misplaced_attachment_count
  end

  def test_restore_hands_the_mail_back_to_its_ticket
    ticket = ticket!(1)
    mail   = mail!(1, 'Issue', 1)
    other  = mail!(4, 'Issue', 4)
    ticket!(4)

    result = Import.new(['1']).restore_attachments

    assert_equal 1, result.attachments_restored
    assert_equal ['HelpdeskTicket', ticket], mail.reload.slice(:container_type, :container_id).values
    assert_equal 'Issue', other.reload.container_type, 'unselected project must stay untouched'
  end

  def test_restore_skips_an_issue_with_two_tickets
    ticket!(1)
    ticket!(1)
    mail = mail!(1, 'Issue', 1)

    assert_equal 0, Import.new(['1']).restore_attachments.attachments_restored
    assert_equal 'Issue', mail.reload.container_type
  end

  def test_restore_skips_an_issue_with_two_mails
    ticket!(1)
    first  = mail!(1, 'Issue', 1)
    second = mail!(4, 'Issue', 1)
    second.update_columns(:content_type => 'application/octet-stream') # still a second message.eml

    assert_equal 0, Import.new(['1']).restore_attachments.attachments_restored
    assert_equal 'Issue', first.reload.container_type
  end

  def test_restore_skips_a_ticket_that_already_holds_a_mail
    ticket = ticket!(1)
    mail!(4, 'HelpdeskTicket', ticket)
    mail = mail!(1, 'Issue', 1)

    assert_equal 0, Import.new(['1']).restore_attachments.attachments_restored
    assert_equal 'Issue', mail.reload.container_type
  end

  def test_restore_leaves_our_own_archived_mails_alone
    ticket!(1)
    ours = mail!(1, 'Issue', 1, 'original_mail_20260925_101500.eml')

    assert_equal 0, Import.new(['1']).restore_attachments.attachments_restored
    assert_equal 'Issue', ours.reload.container_type
  end

  def test_project_options_count_both_directions
    mail!(1, 'HelpdeskTicket', ticket!(2)) # project 1: fixable
    ticket!(4)
    mail!(4, 'Issue', 4)                   # project 2: restorable
    Import.stubs(:redmineup_helpdesk_installed?).returns(true)

    options = Import.attachment_project_options.index_by { |o| o[:project_id] }
    assert_equal [1, 0], options[1].values_at(:fixable, :restorable)
    assert_equal [0, 1], options[2].values_at(:fixable, :restorable)
  end

  def test_the_no_project_bucket_selects_no_attachments
    mail!(1, 'HelpdeskTicket', ticket!(1))
    assert_equal 0, Import.new(['none']).fix_attachments.attachments_fixed
  end
end
