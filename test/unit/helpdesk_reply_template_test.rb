require File.expand_path('../../test_helper', __FILE__)

# Answer templates: validations, scope resolution (project before global) and
# macro expansion.
class HelpdeskReplyTemplateTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    HelpdeskReplyTemplate.delete_all
    @project = Project.find(1)
    @other   = Project.find(2)
  end

  def build_template(attrs = {})
    HelpdeskReplyTemplate.new({ :name => 'Vorlage', :content => 'Inhalt' }.merge(attrs))
  end

  # --- Validation --------------------------------------------------------

  def test_name_and_content_are_required
    assert_not build_template(:name => '').valid?
    assert_not build_template(:content => '').valid?
    assert build_template.valid?
  end

  # A project may override a global template by using the same name.
  def test_same_name_allowed_once_globally_and_once_per_project
    assert build_template(:project_id => nil).save
    assert build_template(:project_id => @project.id).save
    assert_not build_template(:project_id => @project.id).valid?
  end

  # --- Scope -------------------------------------------------------------

  def test_available_for_returns_project_templates_before_global
    build_template(:name => 'Global',  :project_id => nil).save!
    build_template(:name => 'Projekt', :project_id => @project.id).save!

    names = HelpdeskReplyTemplate.available_for(@project).map(&:name)

    assert_equal %w[Projekt Global], names
  end

  def test_available_for_excludes_other_projects
    build_template(:name => 'Fremd', :project_id => @other.id).save!

    assert_equal [], HelpdeskReplyTemplate.available_for(@project).map(&:name)
  end

  def test_active_excludes_disabled_templates
    build_template(:name => 'Aus', :project_id => @project.id, :enabled => false).save!
    build_template(:name => 'An',  :project_id => @project.id).save!

    names = HelpdeskReplyTemplate.active.available_for(@project).map(&:name)

    assert_equal %w[An], names
  end

  def test_available_for_returns_nothing_without_a_project
    build_template(:project_id => nil).save!

    assert_equal [], HelpdeskReplyTemplate.available_for(nil).to_a
  end

  # Globals must not share numbering with any project.
  def test_position_sequence_is_independent_per_scope
    first  = build_template(:name => 'P1', :project_id => @project.id)
    second = build_template(:name => 'P2', :project_id => @project.id)
    global = build_template(:name => 'G1', :project_id => nil)
    [first, second, global].each(&:save!)

    assert_equal 1, first.reload.position
    assert_equal 2, second.reload.position
    assert_equal 1, global.reload.position
  end

  def test_global_predicate
    assert build_template(:project_id => nil).global?
    assert_not build_template(:project_id => @project.id).global?
  end

  # --- Macros ------------------------------------------------------------

  def test_render_for_expands_macros
    issue    = Issue.find(1)
    template = build_template(:content => 'Ticket {{issue.id}} für {{contact.name}}')
    contact  = HelpdeskContact.new(:name => 'Max Mustermann', :email => 'max@example.de')

    assert_equal "Ticket #{issue.id} für Max Mustermann",
                 template.render_for(issue, contact, User.find(1))
  end

  def test_render_for_tolerates_a_missing_contact
    issue    = Issue.find(1)
    template = build_template(:content => 'Hallo {{contact.name}}!')

    assert_equal 'Hallo !', template.render_for(issue, nil, User.find(1))
  end

  # --- Cleanup -----------------------------------------------------------

  def test_project_destroy_removes_its_templates_but_not_global_ones
    build_template(:name => 'Projekt', :project_id => @other.id).save!
    build_template(:name => 'Global',  :project_id => nil).save!

    @other.destroy

    assert_equal %w[Global], HelpdeskReplyTemplate.pluck(:name)
  end
end
