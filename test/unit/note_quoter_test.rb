require File.expand_path('../../test_helper', __FILE__)

# Quotes of prior ticket content for pasting into a reply to the customer.
class NoteQuoterTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    User.current = User.find(1)
    @issue = Issue.find(1)
    @issue.update_columns(:description => "Erste Zeile\nZweite Zeile")
    @issue.journals.delete_all
    HelpdeskMessage.where(:issue_id => @issue.id).delete_all
  end

  def teardown
    User.current = nil
  end

  def contact(name)
    HelpdeskContact.create!(:project_id => @issue.project_id, :email => 'adolfo@example.es', :name => name)
  end

  def add_note(notes, user, private_notes: false)
    Journal.create!(:journalized => @issue, :user => user,
                    :notes => notes, :private_notes => private_notes)
  end

  # --- description -------------------------------------------------------

  def test_description_prefixes_every_line
    content = RedmineExpertHelpdesk::NoteQuoter.description(@issue).content

    assert_include '> Erste Zeile', content
    assert_include '> Zweite Zeile', content
    assert content.end_with?("\n\n"), 'quote must close with a blank line'
  end

  def test_description_header_names_the_author
    content = RedmineExpertHelpdesk::NoteQuoter.description(@issue).content

    assert_include @issue.author.name, content.lines.first
  end

  def test_description_is_empty_for_blank_description
    @issue.update_columns(:description => '')

    assert_equal '', RedmineExpertHelpdesk::NoteQuoter.description(@issue).content
  end

  def test_crlf_and_cr_line_endings_are_normalised
    @issue.update_columns(:description => "a\r\nb\rc")
    content = RedmineExpertHelpdesk::NoteQuoter.description(@issue).content

    assert_include "> a\n> b\n> c", content
  end

  # --- conversation ------------------------------------------------------

  def test_conversation_includes_description_and_public_notes
    add_note('Oeffentliche Antwort', User.find(2))
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_include '> Erste Zeile', content
    assert_include '> Oeffentliche Antwort', content
  end

  # Rule between the entries: makes a long history easier to skim.
  def test_entries_are_separated_by_a_horizontal_rule
    add_note('Zweiter Eintrag', User.find(2))
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_include "\n\n---\n\n", content
    assert_equal 1, content.scan(/^---$/).size
  end

  # The rule must sit on a blank line, otherwise CommonMark turns
  # "paragraph + ---" into a heading rather than a rule.
  def test_separator_is_preceded_by_a_blank_line
    add_note('Zweiter Eintrag', User.find(2))
    lines = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content.split("\n", -1)
    index = lines.index('---')

    assert_not_nil index
    assert_equal '', lines[index - 1]
    assert_equal '', lines[index + 1]
  end

  def test_single_entry_has_no_separator
    assert_not_include '---', RedmineExpertHelpdesk::NoteQuoter.description(@issue).content
  end

  # The result is meant to be sent to the customer, so "may the acting user see
  # it" is the wrong question — private notes are never quoted.
  def test_conversation_excludes_private_notes_even_for_a_privileged_user
    add_note('Geheime interne Notiz', User.find(2), :private_notes => true)
    User.current = User.find(1) # admin, allowed to view private notes
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_not_include 'Geheime interne Notiz', content
  end

  def test_conversation_skips_journals_without_notes
    Journal.create!(:journalized => @issue, :user => User.find(2), :notes => '')
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_equal RedmineExpertHelpdesk::NoteQuoter.description(@issue).content, content
  end

  # Bookkeeping notes the plugin writes itself (autoresponder sent, phishing
  # links removed) are public and authored by User.anonymous.
  def test_conversation_excludes_anonymous_bookkeeping_notes
    add_note('Automatische Bestaetigungsmail versendet.', User.anonymous)
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_not_include 'Automatische Bestaetigungsmail', content
  end

  # A customer mail filed under the anonymous user carries a HelpdeskMessage and
  # must survive the rule above.
  def test_conversation_keeps_anonymous_note_that_is_a_customer_mail
    journal = add_note('Kundenantwort per Mail', User.anonymous)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in', :journal_id => journal.id)
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_include '> Kundenantwort per Mail', content
  end

  # --- sender names ------------------------------------------------------

  # A mail from a sender without a Redmine account is filed under the
  # anonymous user; the quote names the helpdesk contact instead.
  def test_description_of_an_unknown_sender_names_the_contact
    @issue.update_columns(:author_id => User.anonymous.id)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in', :helpdesk_contact => contact('Adolfo Ortiz'))
    header = RedmineExpertHelpdesk::NoteQuoter.description(@issue.reload).content.lines.first

    assert_include 'Adolfo Ortiz', header
    assert_not_include User.anonymous.name, header
  end

  def test_contact_without_a_name_is_named_by_address
    @issue.update_columns(:author_id => User.anonymous.id)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in', :helpdesk_contact => contact(nil))
    header = RedmineExpertHelpdesk::NoteQuoter.description(@issue.reload).content.lines.first

    assert_include 'adolfo@example.es', header
  end

  def test_customer_reply_filed_as_anonymous_names_the_contact
    journal = add_note('Kundenantwort per Mail', User.anonymous)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in', :journal_id => journal.id,
                            :helpdesk_contact => contact('Adolfo Ortiz'))
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true).content

    assert_include 'Adolfo Ortiz', content
    assert_not_include User.anonymous.name, content
  end

  # A sender who has a Redmine account keeps the name of that account.
  def test_real_user_keeps_their_name
    journal = add_note('Antwort eines Kunden mit Konto', User.find(2))
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in', :journal_id => journal.id,
                            :helpdesk_contact => contact('Someone Else'))
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue).content

    assert_include User.find(2).name, content
    assert_not_include 'Someone Else', content
  end

  # --- mail conversation -------------------------------------------------

  def test_mail_conversation_keeps_only_linked_journals
    linked = add_note('Per Mail gesendet', User.find(2))
    add_note('Interne oeffentliche Notiz', User.find(2))
    HelpdeskMessage.create!(:issue => @issue, :direction => 'out', :journal_id => linked.id)

    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true).content

    assert_include '> Per Mail gesendet', content
    assert_not_include 'Interne oeffentliche Notiz', content
  end

  # An outgoing message whose journal link was never established (autoresponder,
  # initial mail) has no body of its own and simply cannot be quoted.
  def test_mail_conversation_ignores_message_without_journal_link
    add_note('Interne oeffentliche Notiz', User.find(2))
    HelpdeskMessage.create!(:issue => @issue, :direction => 'out', :journal_id => nil)

    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true).content

    assert_equal RedmineExpertHelpdesk::NoteQuoter.description(@issue).content, content
  end

  def test_mail_conversation_always_includes_the_description
    content = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true).content

    assert_include '> Erste Zeile', content
  end

  # --- truncation --------------------------------------------------------

  def test_conversation_is_capped_and_reports_omitted_entries
    (RedmineExpertHelpdesk::NoteQuoter::MAX_ENTRIES + 5).times do |i|
      add_note("Notiz #{i}", User.find(2))
    end
    result = RedmineExpertHelpdesk::NoteQuoter.conversation(@issue)

    assert result.truncated?
    # 1 description + 55 notes = 56 entries, MAX_ENTRIES of which are kept. The
    # description counts towards the cap, so 6 entries fall off the end — it is
    # itself still included (asserted below).
    assert_equal 6, result.omitted
    assert_include '> Erste Zeile', result.content
  end
end
