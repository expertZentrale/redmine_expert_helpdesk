require File.expand_path('../../test_helper', __FILE__)

# Query shape and count of what renders on every ticket page and issue list.
# The results are covered elsewhere (contact history, blacklist eligibility,
# customer and awaiting columns); these tests pin that the work stays cheap:
# no OR over subqueries, which MariaDB answers with a full table scan, and no
# query per list row.
class HelpdeskQueryCostTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    @project = Project.find(1)
    @contact = HelpdeskContact.create!(:email => 'cost@example.org', :name => 'Cost', :project => @project)
    [1, 2, 3].each do |id|
      HelpdeskTicketInfo.where(:issue_id => id).delete_all
      HelpdeskMessage.where(:issue_id => id).delete_all
    end
  end

  # --- HelpdeskContact#issues --------------------------------------------------

  def test_contact_issues_combines_mails_and_linked_tickets
    HelpdeskMessage.create!(:issue => Issue.find(1), :direction => 'in', :helpdesk_contact => @contact)
    HelpdeskMessage.create!(:issue => Issue.find(1), :direction => 'in', :helpdesk_contact => @contact)
    HelpdeskTicketInfo.link!(Issue.find(2), @contact)

    ids = @contact.issues(User.find(1)).order(:id).pluck(:id)
    assert_equal [1, 2], ids
    assert_equal 2, @contact.issues(User.find(1)).count
  end

  def test_contact_issues_queries_issues_by_literal_ids
    HelpdeskMessage.create!(:issue => Issue.find(1), :direction => 'in', :helpdesk_contact => @contact)
    HelpdeskTicketInfo.link!(Issue.find(2), @contact)

    issue_sql = capture_sql { @contact.issues(User.find(1)).order(:id => :desc).limit(4).to_a }
                .select { |sql| sql =~ /FROM [`"]?issues[`"]?/ }
    assert_equal 1, issue_sql.size, issue_sql.join("\n")
    assert_no_match(/helpdesk_(messages|ticket_infos)/, issue_sql.first)
    assert_no_match(/\bOR\b.*\bIN \(SELECT/i, issue_sql.first)
  end

  def test_contact_issues_respects_visibility
    # Issue 4 lives in project 2, which is private.
    HelpdeskTicketInfo.link!(Issue.find(4), @contact)

    assert_includes @contact.issues(User.find(1)).to_a, Issue.find(4)
    assert_not_includes @contact.issues(User.anonymous).to_a, Issue.find(4)
  end

  def test_contact_without_tickets_has_none
    assert_equal [], @contact.issue_ids
    assert_equal 0, @contact.issues(User.find(1)).count
  end

  # --- Attachment blacklist on the ticket page ---------------------------------

  def test_rendered_attachments_avoid_the_or_scan
    issue = Issue.find(1)
    sql = capture_sql { RedmineExpertHelpdesk::AttachmentBlacklist.rendered_attachments(issue) }
          .select { |s| s =~ /FROM [`"]?attachments[`"]?/ }

    assert sql.none? { |s| s =~ /\bOR\b/i }, sql.join("\n")
  end

  def test_rendered_attachments_cover_issue_and_journals
    issue = Issue.find(1)
    journal = issue.journals.first || Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'x')
    on_issue = Attachment.create!(:container => issue, :file => uploaded_test_file('testfile.txt', 'text/plain'),
                                  :author => User.find(1))
    on_journal = Attachment.create!(:container => journal, :file => uploaded_test_file('testfile.txt', 'text/plain'),
                                    :author => User.find(1))

    ids = RedmineExpertHelpdesk::AttachmentBlacklist.rendered_attachments(issue).map(&:id)
    assert_includes ids, on_issue.id
    assert_includes ids, on_journal.id
  end

  # --- Issue list ----------------------------------------------------------------

  def test_issue_list_loads_ticket_infos_once_per_page
    Issue.where(:id => [1, 2, 3]).each { |issue| HelpdeskTicketInfo.mark_awaiting_agent!(issue, 'reply', Time.current) }
    query = IssueQuery.new(:name => '_', :column_names => [:subject, :helpdesk_awaiting_agent, :helpdesk_sla_reaction])

    issues = query.issues(:limit => 25)
    assert_operator issues.size, :>=, 3
    sql = capture_sql do
      issues.each do |issue|
        issue.css_classes
        issue.helpdesk_awaiting_agent
        issue.helpdesk_sla_reaction
        issue.helpdesk_sla_solution
      end
    end

    assert_empty sql.grep(/helpdesk_ticket_infos/), sql.join("\n")
    assert issues.select { |issue| [1, 2, 3].include?(issue.id) }.all? { |issue| issue.css_classes.include?('hd-awaiting') }
  end

  def test_issue_list_loads_customer_contacts_with_the_customer_column
    linked = HelpdeskContact.create!(:email => 'linked@example.org', :name => 'Linked', :project => @project)
    from_mail = HelpdeskContact.create!(:email => 'mail@example.org', :name => 'From Mail', :project => @project)
    HelpdeskTicketInfo.link!(Issue.find(1), linked)
    # Legacy ticket: no ticket info, only the first incoming mail names the customer.
    HelpdeskMessage.create!(:issue => Issue.find(2), :direction => 'in', :helpdesk_contact => from_mail)

    query = IssueQuery.new(:name => '_', :column_names => [:subject, :helpdesk_kunde, :helpdesk_kunde_email])
    issues = query.issues(:limit => 25).index_by(&:id)
    sql = capture_sql { issues.each_value { |issue| issue.helpdesk_kunde; issue.helpdesk_kunde_email } }

    assert_empty sql.grep(/helpdesk_(ticket_infos|messages|contacts)/), sql.join("\n")
    assert_equal 'Linked', issues[1].helpdesk_kunde
    assert_equal 'mail@example.org', issues[2].helpdesk_kunde_email
    assert_nil issues[3].helpdesk_kunde
  end

  def test_issue_list_skips_the_preload_when_nothing_reads_it
    previous = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = previous.merge('awaiting_agent_enabled' => '0')
    query = IssueQuery.new(:name => '_', :column_names => [:subject, :status])

    sql = capture_sql { query.issues(:limit => 25) }
    assert_empty sql.grep(/helpdesk_ticket_infos/), sql.join("\n")
  ensure
    Setting.plugin_redmine_expert_helpdesk = previous
  end

  def test_single_issue_still_looks_its_data_up
    HelpdeskTicketInfo.mark_awaiting_agent!(Issue.find(1), 'reply', Time.current)
    assert_includes Issue.find(1).css_classes.split, 'hd-awaiting'
  end

  private

  def capture_sql
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] unless payload[:name] == 'SCHEMA' || payload[:cached] }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { yield }
    queries
  end
end
