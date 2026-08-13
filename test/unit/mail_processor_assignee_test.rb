require File.expand_path('../../test_helper', __FILE__)

# Default assignee applied to tickets created from incoming mail.
class MailProcessorAssigneeTest < ActiveSupport::TestCase
  # Minimal stand-in for the mail provider - no calls are made here.
  NullProvider = Class.new do
    def method_missing(*); nil; end
    def respond_to_missing?(*); true; end
  end

  IssueStub = Struct.new(:assigned_to_id, :assigned_to)

  def processor_with_default(assignee)
    setting = HelpdeskProjectSetting.new
    setting.stubs(:default_assignee).returns(assignee)
    processor = RedmineExpertHelpdesk::MailProcessor.new(HelpdeskMailbox.new, NullProvider.new)
    processor.stubs(:project_setting).returns(setting)
    processor
  end

  def apply(assignee, issue)
    processor_with_default(assignee).send(:apply_default_assignee, issue)
  end

  def build_group(id, name)
    group = Group.new(:lastname => name)
    group.id = id
    group
  end

  def test_assigns_the_configured_group_when_the_ticket_is_unassigned
    group = build_group(7, 'Support')
    issue = IssueStub.new(nil, nil)
    assert apply(group, issue)
    assert_equal group, issue.assigned_to
  end

  # MailHandler may already have honoured an "Assigned to:" keyword from the
  # mail - that wins over the project default.
  def test_keeps_an_assignee_the_mail_handler_already_set
    issue = IssueStub.new(3, nil)
    assert_not apply(build_group(7, 'Support'), issue)
    assert_nil issue.assigned_to
  end

  def test_does_nothing_without_a_configured_default
    issue = IssueStub.new(nil, nil)
    assert_not apply(nil, issue)
    assert_nil issue.assigned_to
  end
end
