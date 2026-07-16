require File.expand_path('../../test_helper', __FILE__)

class HelpdeskRuleTest < ActiveSupport::TestCase
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
    project = mock('project', :trackers => scope)
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

  def test_apply_to_set_assignee_found
    user    = mock('user', :login => 'john', :id => 5, :present? => true)
    project = mock('project', :users => [user])
    issue   = IssueStub.new(nil, nil, nil, nil, project)
    rule    = build_rule(:action_type => 'set_assignee', :action_value => 'john')
    assert rule.apply_to(issue)
    assert_equal user, issue.assigned_to
  end

  def test_apply_to_set_assignee_not_found
    project = mock('project', :users => [])
    issue   = IssueStub.new(nil, nil, nil, nil, project)
    rule    = build_rule(:action_type => 'set_assignee', :action_value => 'nobody')
    assert_not rule.apply_to(issue)
    assert_nil issue.assigned_to
  end

  def test_apply_to_ignore_returns_false
    issue = IssueStub.new
    rule  = build_rule(:action_type => 'ignore', :action_value => nil)
    assert_not rule.apply_to(issue)
  end
end
