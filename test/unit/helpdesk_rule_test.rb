require File.expand_path('../../test_helper', __FILE__)

class HelpdeskRuleTest < ActiveSupport::TestCase
  # action_value_label resolves principals from the database.
  fixtures :users

  # Minimal issue stand-in for apply_to tests (no DB required).
  IssueStub = Struct.new(:priority, :tracker, :category, :assigned_to, :project)

  def build_rule(attrs = {})
    HelpdeskRule.new({
      :condition_field => 'subject',
      :operator        => 'contains',
      :condition_value => 'dringend',
      :action_type     => 'set_priority',
      :action_value    => 'Hoch'
    }.merge(attrs))
  end

  # Unsaved principals are enough: the resolver only reads id, login and class.
  def build_user(id, login)
    user = User.new(:login => login)
    user.id = id
    user
  end

  def build_group(id, name)
    group = Group.new(:lastname => name)
    group.id = id
    group
  end

  def issue_with_assignables(principals)
    project = mock('project')
    project.stubs(:assignable_users).returns(principals)
    IssueStub.new(nil, nil, nil, nil, project)
  end

  # -----------------------------------------------------------------------
  # matches?
  # -----------------------------------------------------------------------

  def test_contains_matches_case_insensitive
    rule = build_rule
    assert rule.matches?('Sehr DRINGEND bitte', 'kunde@example.de')
    assert_not rule.matches?('Normale Anfrage', 'kunde@example.de')
  end

  def test_equals_on_sender
    rule = build_rule(:condition_field => 'sender', :operator => 'equals',
                      :condition_value => 'Kunde@Example.de')
    assert rule.matches?('Betreff', 'kunde@example.de')
    assert_not rule.matches?('Betreff', 'andere@example.de')
  end

  def test_equals_on_subject_case_insensitive
    rule = build_rule(:operator => 'equals', :condition_value => 'DRINGEND')
    assert rule.matches?('dringend', 'x@y.de')
    assert_not rule.matches?('sehr dringend', 'x@y.de')
  end

  def test_sender_contains
    rule = build_rule(:condition_field => 'sender', :operator => 'contains',
                      :condition_value => 'bulk')
    assert rule.matches?('Betreff', 'bulk-mailer@example.de')
    assert_not rule.matches?('Betreff', 'kunde@example.de')
  end

  def test_regex_matching
    rule = build_rule(:operator => 'regex', :condition_value => '^\[Stoerung\]')
    assert rule.matches?('[Stoerung] Server down', 'x@y.de')
    assert_not rule.matches?('Re: [Stoerung] Server down', 'x@y.de')
  end

  def test_invalid_regex_does_not_raise
    rule = build_rule(:operator => 'regex', :condition_value => '[ungueltig')
    assert_not rule.matches?('irgendwas', 'x@y.de')
  end

  def test_unknown_operator_returns_false
    rule = build_rule
    rule.operator = 'nonexistent'
    assert_not rule.matches?('dringend', 'x@y.de')
  end

  # -----------------------------------------------------------------------
  # Validations
  # -----------------------------------------------------------------------

  def test_invalid_condition_field
    rule = build_rule(:condition_field => 'body')
    rule.valid?
    assert rule.errors[:condition_field].any?
  end

  def test_invalid_operator
    rule = build_rule(:operator => 'starts_with')
    rule.valid?
    assert rule.errors[:operator].any?
  end

  def test_invalid_action_type
    rule = build_rule(:action_type => 'set_color')
    rule.valid?
    assert rule.errors[:action_type].any?
  end

  def test_action_value_required_for_non_ignore
    rule = build_rule(:action_value => nil)
    rule.valid?
    assert rule.errors[:action_value].any?
  end

  def test_ignore_action_does_not_require_action_value
    rule = build_rule(:action_type => 'ignore', :action_value => nil)
    rule.valid?
    assert_not rule.errors[:action_value].any?
  end

  def test_condition_value_required
    rule = build_rule(:condition_value => nil)
    rule.valid?
    assert rule.errors[:condition_value].any?
  end

  # -----------------------------------------------------------------------
  # apply_to
  # -----------------------------------------------------------------------

  def test_apply_to_set_priority_found
    priority = IssuePriority.new(:name => 'Urgent')
    IssuePriority.stubs(:find_by).returns(priority)
    issue = IssueStub.new
    rule  = build_rule(:action_type => 'set_priority', :action_value => 'Urgent')
    assert rule.apply_to(issue)
    assert_equal priority, issue.priority
  end

  def test_apply_to_set_priority_not_found
    IssuePriority.stubs(:find_by).returns(nil)
    issue = IssueStub.new
    rule  = build_rule(:action_type => 'set_priority', :action_value => 'Nope')
    assert_not rule.apply_to(issue)
    assert_nil issue.priority
  end

  def test_apply_to_set_tracker_found
    tracker = Tracker.new(:name => 'Bug')
    scope   = mock('trackers')
    scope.stubs(:find_by).returns(tracker)
    project = mock('project', :trackers => scope)
    issue   = IssueStub.new(nil, nil, nil, nil, project)
    rule    = build_rule(:action_type => 'set_tracker', :action_value => 'Bug')
    assert rule.apply_to(issue)
    assert_equal tracker, issue.tracker
  end

  def test_apply_to_set_tracker_not_found
    scope   = mock('trackers')
    scope.stubs(:find_by).returns(nil)
    # stubs: bei "nicht gefunden" fragt apply_to project.trackers zweimal ab
    # (find_by name || find_by id) — das ist erlaubt, keine feste Aufrufanzahl.
    project = mock('project')
    project.stubs(:trackers).returns(scope)
    issue   = IssueStub.new(nil, nil, nil, nil, project)
    rule    = build_rule(:action_type => 'set_tracker', :action_value => 'Nope')
    assert_not rule.apply_to(issue)
    assert_nil issue.tracker
  end

  def test_apply_to_set_category_found
    category = IssueCategory.new(:name => 'Support')
    scope    = mock('categories')
    scope.stubs(:find_by).returns(category)
    project  = mock('project', :issue_categories => scope)
    issue    = IssueStub.new(nil, nil, nil, nil, project)
    rule     = build_rule(:action_type => 'set_category', :action_value => 'Support')
    assert rule.apply_to(issue)
    assert_equal category, issue.category
  end

  # Legacy rows store the login, so that lookup has to keep working.
  def test_apply_to_set_assignee_by_login
    user  = build_user(5, 'john')
    issue = issue_with_assignables([user])
    rule  = build_rule(:action_type => 'set_assignee', :action_value => 'john')
    assert rule.apply_to(issue)
    assert_equal user, issue.assigned_to
  end

  def test_apply_to_set_assignee_by_principal_id
    user  = build_user(5, 'john')
    issue = issue_with_assignables([user])
    rule  = build_rule(:action_type => 'set_assignee', :action_value => '5')
    assert rule.apply_to(issue)
    assert_equal user, issue.assigned_to
  end

  def test_apply_to_set_assignee_resolves_group
    group = build_group(7, 'Support')
    issue = issue_with_assignables([build_user(5, 'john'), group])
    rule  = build_rule(:action_type => 'set_assignee', :action_value => '7')
    assert rule.apply_to(issue)
    assert_equal group, issue.assigned_to
  end

  def test_apply_to_set_assignee_ignores_non_assignable_principal
    issue = issue_with_assignables([build_user(5, 'john')])
    rule  = build_rule(:action_type => 'set_assignee', :action_value => '99')
    assert_not rule.apply_to(issue)
    assert_nil issue.assigned_to
  end

  def test_apply_to_set_assignee_not_found
    issue = issue_with_assignables([])
    rule  = build_rule(:action_type => 'set_assignee', :action_value => 'nobody')
    assert_not rule.apply_to(issue)
    assert_nil issue.assigned_to
  end

  def test_apply_to_ignore_returns_false
    issue = IssueStub.new
    rule  = build_rule(:action_type => 'ignore', :action_value => nil)
    assert_not rule.apply_to(issue)
  end

  def test_action_value_label_resolves_principal_id
    group = Group.generate!(:name => 'Second Level')
    rule  = build_rule(:action_type => 'set_assignee', :action_value => group.id.to_s)
    assert_equal group.name, rule.action_value_label
  end

  def test_action_value_label_resolves_legacy_login
    user = User.generate!(:login => 'hd_agent')
    rule = build_rule(:action_type => 'set_assignee', :action_value => 'hd_agent')
    assert_equal user.name, rule.action_value_label
  end

  # Redmine allows a login made of digits only - it must not be read as an id.
  def test_action_value_label_prefers_a_numeric_login_over_the_principal_id
    group = Group.generate!(:name => 'Second Level')
    user  = User.generate!(:login => group.id.to_s)
    rule  = build_rule(:action_type => 'set_assignee', :action_value => group.id.to_s)
    assert_equal user.name, rule.action_value_label
  end

  def test_action_value_label_falls_back_to_raw_value
    rule = build_rule(:action_type => 'set_assignee', :action_value => 'ghost')
    assert_equal 'ghost', rule.action_value_label
  end

  def test_action_value_label_passes_other_actions_through
    rule = build_rule(:action_type => 'set_priority', :action_value => 'Hoch')
    assert_equal 'Hoch', rule.action_value_label
  end
end
