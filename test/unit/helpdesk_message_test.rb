require File.expand_path('../../test_helper', __FILE__)

class HelpdeskMessageTest < ActiveSupport::TestCase
  fixtures :all

  # -----------------------------------------------------------------------
  # Constants
  # -----------------------------------------------------------------------

  def test_directions_constant_contains_all_expected_values
    assert_includes HelpdeskMessage::DIRECTIONS, 'in'
    assert_includes HelpdeskMessage::DIRECTIONS, 'out'
    assert_includes HelpdeskMessage::DIRECTIONS, 'init'
    assert_equal 3, HelpdeskMessage::DIRECTIONS.size
  end

  # -----------------------------------------------------------------------
  # Validations (in-memory, no DB write needed)
  # -----------------------------------------------------------------------

  def test_direction_must_be_valid
    msg = HelpdeskMessage.new(:issue => Issue.first, :direction => 'unknown')
    msg.valid?
    assert msg.errors[:direction].any?
  end

  def test_all_defined_directions_pass_direction_validation
    HelpdeskMessage::DIRECTIONS.each do |dir|
      msg = HelpdeskMessage.new(:issue => Issue.first, :direction => dir)
      msg.valid?
      assert_not msg.errors[:direction].any?, "direction '#{dir}' should be valid"
    end
  end

  def test_issue_is_required
    msg = HelpdeskMessage.new(:direction => 'in')
    msg.valid?
    assert msg.errors[:issue].any?
  end

  # -----------------------------------------------------------------------
  # Scopes
  # -----------------------------------------------------------------------

  def test_incoming_scope_includes_inbound_messages
    issue = Issue.first
    msg   = HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    assert_includes HelpdeskMessage.incoming, msg
  end

  def test_incoming_scope_excludes_outbound_and_init_messages
    issue    = Issue.first
    msg_out  = HelpdeskMessage.create!(:issue => issue, :direction => 'out')
    msg_init = HelpdeskMessage.create!(:issue => issue, :direction => 'init')
    assert_not_includes HelpdeskMessage.incoming, msg_out
    assert_not_includes HelpdeskMessage.incoming, msg_init
  end

  def test_outgoing_scope_includes_outbound_messages
    issue = Issue.first
    msg   = HelpdeskMessage.create!(:issue => issue, :direction => 'out')
    assert_includes HelpdeskMessage.outgoing, msg
  end

  def test_outgoing_scope_excludes_inbound_and_init_messages
    issue    = Issue.first
    msg_in   = HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    msg_init = HelpdeskMessage.create!(:issue => issue, :direction => 'init')
    assert_not_includes HelpdeskMessage.outgoing, msg_in
    assert_not_includes HelpdeskMessage.outgoing, msg_init
  end

  # -----------------------------------------------------------------------
  # Original recipients (offered behind the reply form's To/Cc fields)
  # -----------------------------------------------------------------------

  def inbound(issue, to, cc = nil)
    HelpdeskMessage.create!(:issue => issue, :direction => 'in',
                            :recipient_to => to, :recipient_cc => cc)
  end

  def test_original_recipients_returns_to_and_cc_of_the_inbound_mail
    issue = Issue.first
    inbound(issue, 'support@example.com, chef@kunde.de', 'kollege@kunde.de')

    result = HelpdeskMessage.original_recipients_for(issue)
    assert_equal ['support@example.com', 'chef@kunde.de'], result[:to]
    assert_equal ['kollege@kunde.de'], result[:cc]
  end

  # The mailbox that received the mail is always in its To, and the customer is
  # already prefilled in the form - both are passed in as exclusions.
  def test_original_recipients_filters_excluded_addresses_case_insensitively
    issue = Issue.first
    inbound(issue, 'Support@Example.com, chef@kunde.de', 'kunde@kunde.de')

    result = HelpdeskMessage.original_recipients_for(
      issue, :exclude => ['support@example.com', 'KUNDE@kunde.de']
    )
    assert_equal ['chef@kunde.de'], result[:to]
    assert_equal [], result[:cc]
  end

  # Offering it twice would let the agent put a duplicate recipient on the mail.
  def test_original_recipients_offers_an_address_in_both_headers_only_once
    issue = Issue.first
    inbound(issue, 'chef@kunde.de', 'chef@kunde.de, kollege@kunde.de')

    result = HelpdeskMessage.original_recipients_for(issue)
    assert_equal ['chef@kunde.de'], result[:to]
    assert_equal ['kollege@kunde.de'], result[:cc]
  end

  # MailProcessor parses the MIME with a `rescue nil`, so a mail that failed to
  # parse stores NULL rather than an empty string.
  def test_original_recipients_handles_null_columns
    issue = Issue.first
    inbound(issue, nil, nil)

    result = HelpdeskMessage.original_recipients_for(issue)
    assert_equal [], result[:to]
    assert_equal [], result[:cc]
  end

  def test_original_recipients_is_empty_without_an_inbound_mail
    issue = Issue.first
    HelpdeskMessage.create!(:issue => issue, :direction => 'out',
                            :recipient_to => 'kunde@kunde.de')

    result = HelpdeskMessage.original_recipients_for(issue)
    assert_equal [], result[:to]
    assert_equal [], result[:cc]
  end

  # The mail that opened the ticket, not the most recent one: a later reply may
  # have dropped people the answer should still reach.
  def test_original_recipients_uses_the_first_inbound_mail
    issue = Issue.first
    inbound(issue, 'first@kunde.de')
    inbound(issue, 'second@kunde.de')

    assert_equal ['first@kunde.de'], HelpdeskMessage.original_recipients_for(issue)[:to]
  end

  def test_original_recipients_strips_display_names_and_blank_entries
    issue = Issue.first
    inbound(issue, 'Chef <chef@kunde.de>, , kollege@kunde.de;')

    assert_equal ['chef@kunde.de', 'kollege@kunde.de'],
                 HelpdeskMessage.original_recipients_for(issue)[:to]
  end

  # A comma inside a quoted display name separates nothing. Splitting on every
  # comma tore this into '"Doe' and 'Jane" <jane@doe.com>' and offered both.
  def test_original_recipients_keeps_a_quoted_display_name_with_a_comma_intact
    issue = Issue.first
    inbound(issue, '"Doe, Jane" <jane@doe.com>, chef@kunde.de')

    assert_equal ['jane@doe.com', 'chef@kunde.de'],
                 HelpdeskMessage.original_recipients_for(issue)[:to]
  end

  # An escaped quote does not close the quoted string. Toggling on it flipped
  # the parity, so the comma after the first address looked unquoted and split
  # the display name in half - offering '"Doe \" Jane' as a recipient.
  def test_original_recipients_survives_an_escaped_quote_in_the_display_name
    issue = Issue.first
    inbound(issue, '"Doe \" Jane, X" <jane@doe.com>, chef@kunde.de')

    assert_equal ['jane@doe.com', 'chef@kunde.de'],
                 HelpdeskMessage.original_recipients_for(issue)[:to]
  end

  # The caller passes the mailbox it would reply *from*, and reply_form falls
  # back to the first enabled project mailbox once the ticket's original mailbox
  # is disabled. The receiving mailbox must drop out regardless, or we offer our
  # own helpdesk address back and the answer loops into the helpdesk.
  def test_original_recipients_excludes_the_mailbox_that_received_the_mail
    issue   = Issue.first
    mailbox = HelpdeskMailbox.create!(:project         => issue.project,
                                      :mailbox_address => 'support@expert.local',
                                      :provider        => 'imap',
                                      :imap_host       => 'mail.example.com')
    HelpdeskMessage.create!(:issue            => issue,
                            :direction        => 'in',
                            :helpdesk_mailbox => mailbox,
                            :recipient_to     => 'support@expert.local, chef@kunde.de')

    # Deliberately no :exclude - the message knows which mailbox received it.
    assert_equal ['chef@kunde.de'], HelpdeskMessage.original_recipients_for(issue)[:to]
  end
end
