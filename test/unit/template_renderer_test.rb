require File.expand_path('../../test_helper', __FILE__)

class TemplateRendererTest < ActiveSupport::TestCase
  # Kernfixtures von Redmine: die Makro-Tests lesen echte Issues, Benutzer
  # und benutzerdefinierte Felder statt Mocks, damit Sichtbarkeit und
  # Feldformate mitgetestet werden.
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :issue_categories, :trackers, :enumerations,
           :versions, :enabled_modules, :workflows,
           :custom_fields, :custom_values, :custom_fields_trackers,
           :custom_fields_projects

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
    # stubs statt mock(attr => val): der Renderer darf Felder wie issue.id
    # mehrfach lesen; wir pruefen die Ausgabe, nicht die Aufrufanzahl.
    project = mock('project')
    project.stubs(:name).returns('Support')
    issue = mock('issue')
    issue.stubs(:id).returns(42)
    issue.stubs(:subject).returns('Server ausgefallen')
    issue.stubs(:project).returns(project)
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
    project = mock('project')
    project.stubs(:name).returns('P')
    issue = mock('issue')
    issue.stubs(:id).returns(7)
    issue.stubs(:subject).returns('x')
    issue.stubs(:project).returns(project)
    Setting.stubs(:host_name).returns('redmine.example.de')
    Setting.stubs(:protocol).returns('https')
    result = RedmineExpertHelpdesk::TemplateRenderer.render('{{issue.url}}', :issue => issue)
    assert_equal 'https://redmine.example.de/issues/7', result
  end

  def test_legacy_and_dot_notation_are_equivalent
    project = mock('project')
    project.stubs(:name).returns('Demo')
    issue = mock('issue')
    issue.stubs(:id).returns(1)
    issue.stubs(:subject).returns('Test')
    issue.stubs(:project).returns(project)
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

  # --- Erweiterte Issue-Makros -------------------------------------------

  def test_renders_extended_issue_macros
    issue = Issue.find(1)
    result = RedmineExpertHelpdesk::TemplateRenderer.render(
      '{{issue.status}}|{{issue.priority}}|{{issue.tracker}}|{{issue.author}}|{{issue.done_ratio}}',
      :issue => issue
    )
    assert_equal [issue.status.name, issue.priority.name, issue.tracker.name,
                  issue.author.name, "#{issue.done_ratio}%"].join('|'),
                 result
  end

  def test_unset_issue_association_renders_empty
    issue = Issue.find(1)
    issue.stubs(:assigned_to).returns(nil)
    issue.stubs(:category).returns(nil)
    assert_equal '--', RedmineExpertHelpdesk::TemplateRenderer.render(
      '-{{issue.assignee}}{{issue.category}}-', :issue => issue
    )
  end

  # Resolution is lazy: a template that only uses issue.id must not touch any
  # other field, which is what lets mocked issues render at all.
  def test_resolution_is_lazy
    issue = mock('issue')
    issue.stubs(:id).returns(5)
    assert_equal '5', RedmineExpertHelpdesk::TemplateRenderer.render('{{issue.id}}', :issue => issue)
  end

  # --- Agent-Makros -------------------------------------------------------

  def test_renders_agent_macros
    user = User.find(2)
    result = RedmineExpertHelpdesk::TemplateRenderer.render(
      '{{user.firstname}} {{user.lastname}} <{{user.mail}}> ({{user.login}})',
      :user => user
    )
    assert_equal "#{user.firstname} #{user.lastname} <#{user.mail}> (#{user.login})", result
  end

  # --- Benutzerdefinierte Felder -----------------------------------------

  def test_custom_field_macro_requires_admin_opt_in
    issue = Issue.find(1)
    cf = issue.available_custom_fields.first
    assert_not_nil cf, 'fixture issue 1 needs a custom field'

    with_macro_custom_fields('') do
      assert_equal '', RedmineExpertHelpdesk::TemplateRenderer.render(
        "{{issue.cf.#{cf.id}}}", :issue => issue, :user => User.find(1)
      )
    end
  end

  def test_custom_field_macro_by_id_and_by_slug_are_equivalent
    issue = Issue.find(1)
    cf = issue.available_custom_fields.detect { |f| issue.custom_field_value(f).present? }
    assert_not_nil cf, 'fixture issue 1 needs a custom field with a value'
    slug = RedmineExpertHelpdesk::TemplateRenderer.slugify(cf.name)

    with_macro_custom_fields(cf.id.to_s) do
      by_id   = RedmineExpertHelpdesk::TemplateRenderer.render("{{issue.cf.#{cf.id}}}",
                                                              :issue => issue, :user => User.find(1))
      by_slug = RedmineExpertHelpdesk::TemplateRenderer.render("{{issue.cf.#{slug}}}",
                                                              :issue => issue, :user => User.find(1))
      assert_equal by_id, by_slug
      assert by_id.present?, 'custom field macro rendered empty'
    end
  end

  def test_custom_field_macro_respects_field_visibility
    issue = Issue.find(1)
    cf = issue.available_custom_fields.detect { |f| issue.custom_field_value(f).present? }
    assert_not_nil cf
    # Opted in by the admin, but invisible to the acting agent -> empty.
    IssueCustomField.any_instance.stubs(:visible_by?).returns(false)

    with_macro_custom_fields(cf.id.to_s) do
      assert_equal '', RedmineExpertHelpdesk::TemplateRenderer.render(
        "{{issue.cf.#{cf.id}}}", :issue => issue, :user => User.find(2)
      )
    end
  end

  def test_unknown_custom_field_renders_empty
    issue = Issue.find(1)
    with_macro_custom_fields('') do
      assert_equal '', RedmineExpertHelpdesk::TemplateRenderer.render(
        '{{issue.cf.gibtsnicht}}', :issue => issue
      )
    end
  end

  def test_slugify
    assert_equal 'vertragsnummer', RedmineExpertHelpdesk::TemplateRenderer.slugify('Vertragsnummer')
    assert_equal 'kunden_nr', RedmineExpertHelpdesk::TemplateRenderer.slugify('Kunden-Nr.')
    assert_equal 'a_b', RedmineExpertHelpdesk::TemplateRenderer.slugify('  A / B  ')
  end

  # Deutsche Feldnamen sind der Regelfall; ein Umlaut darf nicht als
  # Unterstrich enden ("zust_ndigkeit").
  def test_slugify_spells_out_umlauts
    r = RedmineExpertHelpdesk::TemplateRenderer
    assert_equal 'zustaendigkeit', r.slugify('Zuständigkeit')
    assert_equal 'loesung',        r.slugify('Lösung')
    assert_equal 'bgv_a3_geprueft', r.slugify('BGV A3 geprüft')
    assert_equal 'rueckmeldung_von_ges_erhalten', r.slugify('Rückmeldung von Ges. erhalten')
    assert_equal 'strasse',        r.slugify('Straße')
  end

  # Ein doppelt verwendeter Wert darf den Accessor nur einmal treffen —
  # sonst kostet jede Wiederholung im Template einen weiteren DB-Zugriff.
  def test_repeated_macro_resolves_value_only_once
    user = mock('user')
    user.expects(:name).once.returns('Julia Meier')
    result = RedmineExpertHelpdesk::TemplateRenderer.render(
      '{{user.name}} / {{user_name}} / {{user.name}}', :user => user
    )
    assert_equal 'Julia Meier / Julia Meier / Julia Meier', result
  end

  # --- Katalog ------------------------------------------------------------

  # Chips und Settings-Hinweis lesen den Katalog, der Renderer muss also jedes
  # angebotene Makro auch wirklich aufloesen koennen.
  def test_catalogue_entries_are_all_resolvable
    RedmineExpertHelpdesk::TemplateRenderer.catalogue.each do |macro|
      assert_nothing_raised do
        RedmineExpertHelpdesk::TemplateRenderer.render("{{#{macro}}}", :issue => Issue.find(1),
                                                       :user => User.find(2))
      end
    end
  end

  private

  def with_macro_custom_fields(value)
    settings = Setting.plugin_redmine_expert_helpdesk.dup
    settings['macro_custom_field_ids'] = value
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns(settings)
    yield
  end
end
