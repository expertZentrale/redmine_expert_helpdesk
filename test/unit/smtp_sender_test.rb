require File.expand_path('../../test_helper', __FILE__)

class SmtpSenderTest < ActiveSupport::TestCase
  Sender = RedmineExpertHelpdesk::SmtpSender

  MIME_WITH_BCC = <<~MIME.freeze
    From: hd@example.com
    To: kunde@example.de
    Cc: kollege@example.de
    Bcc: archiv@example.com
    Subject: Test
    MIME-Version: 1.0
    Content-Type: text/plain

    Hallo.
  MIME

  # Records what would go over the wire.
  class FakeSmtpSession
    attr_reader :sent

    def send_message(body, from, to)
      @sent = { :body => body, :from => from, :to => Array(to) }
    end
  end

  class StubbedSender < Sender
    attr_reader :session

    def initialize(mailbox, credentials)
      super(mailbox, credentials)
      @session = FakeSmtpSession.new
    end

    private

    def start
      yield @session
    end
  end

  def setup
    @mailbox = HelpdeskMailbox.new(
      :mailbox_address => 'hd@example.com',
      :provider        => 'imap',
      :smtp_host       => 'smtp.example.com',
      :auth_method     => 'password'
    )
    @sender = StubbedSender.new(@mailbox, credentials)
  end

  # Exchange strips Bcc for us; a real SMTP server does not, so leaving the
  # header in place would expose blind recipients to everyone.
  def test_bcc_moves_from_header_into_the_envelope
    @sender.send_mime(MIME_WITH_BCC)
    sent = @sender.session.sent

    assert_equal %w[kunde@example.de kollege@example.de archiv@example.com].sort,
                 sent[:to].sort
    assert_not_match(/^Bcc:/i, sent[:body])
    assert_match(/^Cc: kollege@example\.de/i, sent[:body])
  end

  def test_envelope_sender_is_the_mailbox
    @sender.send_mime(MIME_WITH_BCC)
    assert_equal 'hd@example.com', @sender.session.sent[:from]
  end

  def test_mail_without_recipients_is_rejected
    mime = "From: hd@example.com\nSubject: x\n\nbody\n"
    assert_raise(Sender::SmtpError) { @sender.send_mime(mime) }
  end

  def test_password_auth_requires_a_password
    assert @sender.configured?

    creds = credentials
    creds.password = nil
    assert_not StubbedSender.new(@mailbox, creds).configured?
  end

  def test_not_configured_without_host
    @mailbox.smtp_host = nil
    assert_not StubbedSender.new(@mailbox, credentials).configured?
  end

  private

  def credentials
    RedmineExpertHelpdesk::Credentials.new(
      :auth_method => 'password', :username => 'hd@example.com', :password => 'pw'
    )
  end
end
