require File.expand_path('../../test_helper', __FILE__)

# Endpoint delivering quotes and expanded answer templates for the note field.
# Session-authenticated (no API key), always answers with JSON.
class HelpdeskNoteContentTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals, :journal_details

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:send_helpdesk_reply, :view_helpdesk_info)
    @issue = Issue.find(1)
    @issue.update_columns(:description => 'Der Drucker geht nicht.')
    HelpdeskReplyTemplate.delete_all
    log_user('jsmith', 'jsmith') # Manager in Projekt 1
  end

  def post_content(params)
    post "/issues/#{@issue.id}/helpdesk_note_content", :params => params,
         :headers => { 'Accept' => 'application/json' }
  end

  def json
    JSON.parse(response.body)
  end

  # --- Quotes ------------------------------------------------------------

  def test_description_returns_the_quoted_description
    post_content(:source => 'description')

    assert_response :success
    assert_include '> Der Drucker geht nicht.', json['content']
    assert_equal false, json['truncated']
  end

  def test_conversation_and_mail_conversation_are_accepted
    %w[conversation mail_conversation].each do |source|
      post_content(:source => source)
      assert_response :success, "source #{source} should be accepted"
      assert_include '> Der Drucker geht nicht.', json['content']
    end
  end

  def test_unknown_source_is_rejected
    post_content(:source => 'nonsense')

    assert_response :unprocessable_entity
    assert json['error'].present?
  end

  def test_empty_content_is_reported_as_an_error
    @issue.update_columns(:description => '')
    post_content(:source => 'description')

    assert_response :unprocessable_entity
    assert json['error'].present?
  end

  # The endpoint hands out journal text — private notes must not show up even
  # for users allowed to read them.
  def test_private_notes_are_not_quoted
    Role.find(1).add_permission!(:view_private_notes)
    Journal.create!(:journalized => @issue, :user => User.find(2),
                    :notes => 'Streng interne Notiz', :private_notes => true)
    post_content(:source => 'conversation')

    assert_response :success
    assert_not_include 'Streng interne Notiz', json['content']
  end

  # --- Answer templates --------------------------------------------------

  def test_template_is_returned_with_macros_expanded
    template = HelpdeskReplyTemplate.create!(:project_id => @project.id,
                                             :name => 'Eingangsbestaetigung',
                                             :content => 'Ihr Ticket {{issue.id}} ist eingegangen.')
    post_content(:source => 'template', :template_id => template.id)

    assert_response :success
    assert_equal "Ihr Ticket #{@issue.id} ist eingegangen.", json['content']
  end

  def test_global_template_is_available_in_the_project
    template = HelpdeskReplyTemplate.create!(:project_id => nil, :name => 'Global',
                                             :content => 'Globaler Text')
    post_content(:source => 'template', :template_id => template.id)

    assert_response :success
    assert_equal 'Globaler Text', json['content']
  end

  def test_template_of_another_project_is_not_found
    template = HelpdeskReplyTemplate.create!(:project_id => Project.find(2).id,
                                             :name => 'Fremd', :content => 'Fremder Text')
    post_content(:source => 'template', :template_id => template.id)

    assert_response :not_found
  end

  def test_disabled_template_is_not_available
    template = HelpdeskReplyTemplate.create!(:project_id => @project.id, :name => 'Aus',
                                             :content => 'Text', :enabled => false)
    post_content(:source => 'template', :template_id => template.id)

    assert_response :not_found
  end

  # --- Toolbar in the edit form ------------------------------------------

  def toolbar_island
    node = css_select('script#hd-note-toolbar-data').first
    node && JSON.parse(node.text)
  end

  def test_edit_form_renders_the_toolbar_island_and_its_script
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    island = toolbar_island
    assert_not_nil island, 'the note toolbar JSON island must be rendered'
    assert_equal 'issue_notes', island['textareaId']
    assert_equal "/issues/#{@issue.id}/helpdesk_note_content", island['postUrl']
    assert island['labels']['quoteConversation'].present?
    assert_select 'script[src*=?]', 'helpdesk_note_toolbar'
  end

  def test_toolbar_island_lists_project_templates_before_global_ones
    HelpdeskReplyTemplate.create!(:project_id => nil, :name => 'Global', :content => 'g')
    HelpdeskReplyTemplate.create!(:project_id => @project.id, :name => 'Projekt', :content => 'p')

    get "/issues/#{@issue.id}/edit"

    assert_response :success
    templates = toolbar_island['templates']
    assert_equal %w[Projekt Global], templates.map { |t| t['name'] }
    assert_equal [false, true], templates.map { |t| t['global'] }
  end

  # Template names are user input rendered into a <script> block, so a name
  # containing "</script>" must not be able to break out of the island.
  def test_toolbar_island_escapes_a_template_name_that_closes_the_script_tag
    HelpdeskReplyTemplate.create!(:project_id => @project.id,
                                  :name => '</script><script>alert(1)</script>',
                                  :content => 'x')

    get "/issues/#{@issue.id}/edit"

    assert_response :success
    island = css_select('script#hd-note-toolbar-data').first.text
    assert_not_include '</script>', island
    assert_include 'alert(1)', JSON.parse(island)['templates'].first['name']
  end

  # Without a customer contact the reply form is gone but the toolbar is not:
  # that is exactly when you quote the conversation.
  def test_toolbar_is_rendered_without_a_linked_contact
    assert_nil HelpdeskTicketInfo.for_issue(@issue)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_not_nil toolbar_island
  end

  def test_toolbar_is_absent_without_send_helpdesk_reply
    Role.find(1).remove_permission!(:send_helpdesk_reply)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_nil toolbar_island
  end

  # --- Access control ----------------------------------------------------

  def test_forbidden_without_send_helpdesk_reply
    Role.find(1).remove_permission!(:send_helpdesk_reply)
    post_content(:source => 'description')

    assert_response :forbidden
  end

  def test_not_found_when_the_helpdesk_module_is_disabled
    @project.disable_module!(:helpdesk)
    post_content(:source => 'description')

    assert_response :not_found
  end
end
