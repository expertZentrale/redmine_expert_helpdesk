require File.expand_path('../../test_helper', __FILE__)

# Customer resolution for the issue-list columns "Kunde" and "Kunden-E-Mail":
# the authoritative HelpdeskTicketInfo link wins, the sender of the first
# incoming mail is the legacy fallback, and tickets without a customer stay
# blank. The shared "Kunde" filter must follow the same resolution.
class HelpdeskCustomerEmailColumnTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    @issue = Issue.find(1)
    @other = Issue.find(2)
    [@issue, @other].each do |issue|
      HelpdeskTicketInfo.where(:issue_id => issue.id).delete_all
      HelpdeskMessage.where(:issue_id => issue.id).delete_all
    end
  end

  def create_contact(email, name = nil)
    HelpdeskContact.create!(:email => email, :name => name)
  end

  def incoming_message(issue, contact)
    HelpdeskMessage.create!(:issue => issue, :direction => 'in', :helpdesk_contact => contact)
  end

  # -----------------------------------------------------------------------
  # Issue#helpdesk_kunde_email / #helpdesk_kunde resolution
  # -----------------------------------------------------------------------

  # Agent-assigned customer (init flow): a ticket info exists but no incoming
  # mail. Both columns must show the customer anyway.
  def test_ticket_info_contact_without_incoming_mail
    contact = create_contact('assigned@example.org', 'Assigned Customer')
    HelpdeskTicketInfo.link!(@issue, contact)

    issue = Issue.find(@issue.id)
    assert_equal 'assigned@example.org', issue.helpdesk_kunde_email
    assert_equal 'Assigned Customer', issue.helpdesk_kunde
  end

  # Legacy ticket without a ticket-info row: fall back to the first incoming
  # mail's sender.
  def test_fallback_to_first_incoming_message
    contact = create_contact('legacy@example.org', 'Legacy Customer')
    incoming_message(@issue, contact)

    issue = Issue.find(@issue.id)
    assert_equal 'legacy@example.org', issue.helpdesk_kunde_email
    assert_equal 'Legacy Customer', issue.helpdesk_kunde
  end

  def test_ticket_info_wins_over_first_incoming_sender
    assigned = create_contact('authoritative@example.org', 'Authoritative')
    sender   = create_contact('sender@example.org', 'First Sender')
    HelpdeskTicketInfo.link!(@issue, assigned)
    incoming_message(@issue, sender)

    issue = Issue.find(@issue.id)
    assert_equal 'authoritative@example.org', issue.helpdesk_kunde_email
    assert_equal 'Authoritative', issue.helpdesk_kunde
  end

  # A ticket-info row without a contact (e.g. created by the awaiting flag or
  # SLA tracking) must not mask the message fallback.
  def test_contactless_ticket_info_falls_back_to_message
    contact = create_contact('maskfree@example.org', 'Mask Free')
    HelpdeskTicketInfo.create!(:issue_id => @issue.id)
    incoming_message(@issue, contact)

    assert_equal 'maskfree@example.org', Issue.find(@issue.id).helpdesk_kunde_email
  end

  # A contactless first incoming message (unknown sender) must be skipped in
  # favor of the first incoming message WITH a contact -- in the Ruby resolver
  # and in the SQL mirror (filter/sort) alike.
  def test_contactless_first_incoming_message_is_skipped
    contact = create_contact('second-sender@example.org', 'Second Sender')
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in')
    incoming_message(@issue, contact)

    assert_equal 'second-sender@example.org', Issue.find(@issue.id).helpdesk_kunde_email

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_kunde', '~', ['second-sender'])
    assert_includes query.issues.map(&:id), @issue.id
  end

  # Outgoing/init messages are agent mails, never the customer.
  def test_out_and_init_messages_are_ignored
    agent    = create_contact('agent-only@example.org', 'Agent Only')
    customer = create_contact('real-customer@example.org', 'Real Customer')
    HelpdeskMessage.create!(:issue => @issue, :direction => 'init', :helpdesk_contact => agent)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'out', :helpdesk_contact => agent)
    incoming_message(@issue, customer)

    assert_equal 'real-customer@example.org', Issue.find(@issue.id).helpdesk_kunde_email
  end

  def test_nil_without_any_customer
    issue = Issue.find(@issue.id)
    assert_nil issue.helpdesk_kunde_email
    assert_nil issue.helpdesk_kunde
  end

  # The email column shows the email even when the contact has a name; the name
  # column falls back to the email only for nameless contacts.
  def test_nameless_contact_shows_email_in_both_columns
    contact = create_contact('nameless@example.org')
    HelpdeskTicketInfo.link!(@issue, contact)

    issue = Issue.find(@issue.id)
    assert_equal 'nameless@example.org', issue.helpdesk_kunde_email
    assert_equal 'nameless@example.org', issue.helpdesk_kunde
  end

  # -----------------------------------------------------------------------
  # Query column
  # -----------------------------------------------------------------------

  def test_customer_email_column_is_available
    assert IssueQuery.new(:name => '_').available_columns.any? { |c| c.name == :helpdesk_kunde_email }
  end

  def test_column_caption_resolves_in_both_locales
    column = IssueQuery.new(:name => '_').available_columns.detect { |c| c.name == :helpdesk_kunde_email }
    assert_equal 'Customer email', I18n.with_locale(:en) { column.caption }
    assert_equal 'Kunden-E-Mail',  I18n.with_locale(:de) { column.caption }
  end

  def test_sort_orders_by_customer_email
    first  = create_contact('aaa-sort@example.org', 'Zed')
    second = create_contact('zzz-sort@example.org', 'Abe')
    HelpdeskTicketInfo.link!(@issue, first)
    HelpdeskTicketInfo.link!(@other, second)

    query = IssueQuery.new(:name => '_')
    query.sort_criteria = [['helpdesk_kunde_email', 'desc']]
    ids = query.issues.map(&:id)

    assert_operator ids.index(@other.id), :<, ids.index(@issue.id),
                    'zzz email must sort before aaa email descending'
  end

  # -----------------------------------------------------------------------
  # "Kunde" filter follows the shared resolution
  # -----------------------------------------------------------------------

  # Regression: agent-assigned tickets (ticket info only, no incoming mail)
  # were invisible to the filter before the shared resolver.
  def test_filter_finds_agent_assigned_ticket_by_email
    contact = create_contact('filter-assigned@example.org', 'Filter Assigned')
    HelpdeskTicketInfo.link!(@issue, contact)

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_kunde', '~', ['filter-assigned'])
    ids = query.issues.map(&:id)

    assert_includes ids, @issue.id
    assert_not_includes ids, @other.id
  end

  def test_filter_finds_mail_ticket_by_exact_email
    contact = create_contact('filter-mail@example.org', 'Filter Mail')
    incoming_message(@issue, contact)

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_kunde', '=', ['filter-mail@example.org'])
    ids = query.issues.map(&:id)

    assert_includes ids, @issue.id
    assert_not_includes ids, @other.id
  end

  def test_negated_filter_excludes_matching_ticket
    contact = create_contact('filter-negated@example.org', 'Filter Negated')
    HelpdeskTicketInfo.link!(@issue, contact)

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_kunde', '!~', ['filter-negated'])
    ids = query.issues.map(&:id)

    assert_not_includes ids, @issue.id
    assert_includes ids, @other.id
  end
end
