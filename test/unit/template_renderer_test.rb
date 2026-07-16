require File.expand_path('../../test_helper', __FILE__)

class TemplateRendererTest < ActiveSupport::TestCase
  def test_renders_contact_macros_without_issue
    result = RedmineExpertHelpdesk::TemplateRenderer.render(
      'Hallo {{contact_name}} ({{contact_email}})',
      :contact_name => 'Max Mustermann', :contact_email => 'max@example.de'
    )
    assert_equal 'Hallo Max Mustermann (max@example.de)', result
  end

  def test_unknown_macros_render_empty
    result = RedmineExpertHelpdesk::TemplateRenderer.render('A{{gibtsnicht}}B', {})
    assert_equal 'AB', result
  end

  def test_blank_template_returns_empty_string
    assert_equal '', RedmineExpertHelpdesk::TemplateRenderer.render(nil, {})
    assert_equal '', RedmineExpertHelpdesk::TemplateRenderer.render('', {})
  end

  def test_renders_issue_dot_notation
    project = mock('project', :name => 'Support')
    issue   = mock('issue', :id => 42, :subject => 'Server ausgefallen', :project => project)
    result  = RedmineExpertHelpdesk::TemplateRenderer.render(
      '[#{{issue.id}}] {{issue.subject}} ({{project.name}})',
      :issue => issue
    )
    assert_equal '[#42] Server ausgefallen (Support)', result
  end

  def test_renders_contact_object
    contact = mock('contact', :display_name => 'Max Mustermann', :email => 'max@example.de')
    result  = RedmineExpertHelpdesk::TemplateRenderer.render(
      'An: {{contact.name}} <{{contact.email}}>',
      :contact => contact
    )
    assert_equal 'An: Max Mustermann <max@example.de>', result
  end

  def test_renders_user_object
    user   = mock('user', :name => 'Julia Meier')
    result = RedmineExpertHelpdesk::TemplateRenderer.render(
      'Gesendet von {{user.name}} bzw. {{user_name}}',
      :user => user
    )
    assert_equal 'Gesendet von Julia Meier bzw. Julia Meier', result
  end

  def test_issue_url_uses_setting
    project = mock('project', :name => 'P')
    issue   = mock('issue', :id => 7, :subject => 'x', :project => project)
    Setting.stubs(:host_name).returns('redmine.example.de')
    Setting.stubs(:protocol).returns('https')
    result = RedmineExpertHelpdesk::TemplateRenderer.render('{{issue.url}}', :issue => issue)
    assert_equal 'https://redmine.example.de/issues/7', result
  end

  def test_legacy_and_dot_notation_are_equivalent
    project = mock('project', :name => 'Demo')
    issue   = mock('issue', :id => 1, :subject => 'Test', :project => project)
    Setting.stubs(:host_name).returns('r.example.de')
    Setting.stubs(:protocol).returns('http')
    legacy = RedmineExpertHelpdesk::TemplateRenderer.render(
      '{{ticket_id}} {{ticket_subject}} {{ticket_url}} {{project_name}}',
      :issue => issue
    )
    dot = RedmineExpertHelpdesk::TemplateRenderer.render(
      '{{issue.id}} {{issue.subject}} {{issue.url}} {{project.name}}',
      :issue => issue
    )
    assert_equal legacy, dot
  end
end
