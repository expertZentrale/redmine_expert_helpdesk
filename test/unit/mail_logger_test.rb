require File.expand_path('../../test_helper', __FILE__)

class MailLoggerTest < ActiveSupport::TestCase
  Logger = RedmineExpertHelpdesk::MailLogger

  # Captures what would end up in the Rails log.
  class FakeLogger
    attr_reader :lines

    def initialize
      @lines = []
    end

    %w[debug info warn error].each do |severity|
      define_method(severity) { |message| @lines << [severity, message] }
    end
  end

  FakeMailbox = Struct.new(:mailbox_address, :outgoing_route, :smtp_host, :smtp_port,
                           :smtp_security, :project, :keyword_init => true)

  def setup
    @logger          = FakeLogger.new
    @original_logger = Rails.logger
    Rails.logger     = @logger
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('mail_log_level' => 'info')
  end

  def teardown
    Rails.logger = @original_logger
  end

  def mailbox(route = 'mailbox_smtp')
    FakeMailbox.new(:mailbox_address => 'hd@example.com', :outgoing_route => route,
                    :smtp_host => 'smtp.example.com', :smtp_port => '587',
                    :smtp_security => 'starttls', :project => nil)
  end

  def test_logs_route_and_recipients_on_success
    result = Logger.track(:kind => 'reply', :mailbox => mailbox,
                          :to => 'kunde@example.de', :cc => ['chef@example.de'],
                          :subject => 'Re: [#1] Test') { :delivered }

    assert_equal :delivered, result
    severity, line = @logger.lines.last
    assert_equal 'info', severity
    assert_includes line, 'kind=reply'
    assert_includes line, 'via="mailbox SMTP (smtp.example.com:587)"'
    assert_includes line, 'mailbox=hd@example.com'
    assert_includes line, 'to="kunde@example.de"'
    assert_includes line, 'cc="chef@example.de"'
  end

  def test_honours_configured_level
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('mail_log_level' => 'debug')

    Logger.track(:kind => 'autoresponder', :mailbox => mailbox, :to => 'a@b.de') { nil }

    assert_equal 'debug', @logger.lines.last.first
  end

  def test_failure_is_logged_as_error_and_reraised
    assert_raise(RuntimeError) do
      Logger.track(:kind => 'initial', :mailbox => mailbox('graph'), :to => 'a@b.de') do
        raise 'smtp down'
      end
    end

    severity, line = @logger.lines.last
    assert_equal 'error', severity
    assert_includes line, 'mail FAILED'
    assert_includes line, 'via="Microsoft Graph sendMail"'
    assert_includes line, 'smtp down'
  end

  def test_route_can_be_given_without_a_mailbox
    Logger.track(:kind => 'sla_breach', :route => 'actionmailer', :to => 'ops@example.com') { nil }

    assert_includes @logger.lines.last.last, 'via="Redmine ActionMailer'
  end
end
