require File.expand_path('../../test_helper', __FILE__)

class HelpdeskProjectSettingTest < ActiveSupport::TestCase
  def test_default_subject_template_constant
    assert_equal 'Re: [#{{issue.id}}] {{issue.subject}}',
                 HelpdeskProjectSetting::DEFAULT_SUBJECT_TEMPLATE
  end

  def test_effective_subject_template_returns_default_when_nil
    setting = HelpdeskProjectSetting.new(:reply_subject_template => nil)
    assert_equal HelpdeskProjectSetting::DEFAULT_SUBJECT_TEMPLATE,
                 setting.effective_subject_template
  end

  def test_effective_subject_template_returns_default_when_blank
    setting = HelpdeskProjectSetting.new(:reply_subject_template => '')
    assert_equal HelpdeskProjectSetting::DEFAULT_SUBJECT_TEMPLATE,
                 setting.effective_subject_template
  end

  def test_effective_subject_template_returns_default_for_whitespace_only
    setting = HelpdeskProjectSetting.new(:reply_subject_template => '   ')
    assert_equal HelpdeskProjectSetting::DEFAULT_SUBJECT_TEMPLATE,
                 setting.effective_subject_template
  end

  def test_effective_subject_template_returns_custom_template
    setting = HelpdeskProjectSetting.new(:reply_subject_template => 'Custom: {{issue.subject}}')
    assert_equal 'Custom: {{issue.subject}}', setting.effective_subject_template
  end

  def test_phishing_action_accepts_valid_values
    HelpdeskProjectSetting::PHISHING_ACTIONS.each do |action|
      setting = HelpdeskProjectSetting.new(:phishing_action => action)
      setting.valid?
      assert_empty setting.errors[:phishing_action], "#{action} sollte gueltig sein"
    end
  end

  def test_phishing_action_rejects_invalid_value
    setting = HelpdeskProjectSetting.new(:phishing_action => 'delete_everything')
    setting.valid?
    assert_not_empty setting.errors[:phishing_action]
  end

  def test_effective_phishing_action_defaults_to_neutralize
    assert_equal 'neutralize', HelpdeskProjectSetting.new(:phishing_action => nil).effective_phishing_action
    assert_equal 'neutralize', HelpdeskProjectSetting.new(:phishing_action => 'ungueltig').effective_phishing_action
  end

  def test_effective_phishing_action_returns_quarantine
    setting = HelpdeskProjectSetting.new(:phishing_action => 'quarantine')
    assert_equal 'quarantine', setting.effective_phishing_action
  end

  def test_default_assignee_returns_nil_when_not_configured
    assert_nil HelpdeskProjectSetting.new.default_assignee
  end

  def test_default_assignee_resolves_group
    group = Group.new(:lastname => 'Support')
    group.id = 7
    assert_equal group, setting_with_assignables(7, [group]).default_assignee
  end

  def test_default_assignee_resolves_user
    user = User.new(:login => 'john')
    user.id = 5
    assert_equal user, setting_with_assignables(5, [user]).default_assignee
  end

  # Membership, role or the global group-assignment switch may have changed
  # since the setting was saved - a stale id must not be applied.
  def test_default_assignee_ignores_principal_that_is_no_longer_assignable
    user = User.new(:login => 'john')
    user.id = 5
    assert_nil setting_with_assignables(9, [user]).default_assignee
  end

  private

  def setting_with_assignables(assigned_to_id, principals)
    project = mock('project')
    project.stubs(:assignable_users).returns(principals)
    setting = HelpdeskProjectSetting.new(:default_assigned_to_id => assigned_to_id)
    setting.stubs(:project).returns(project)
    setting
  end
end
