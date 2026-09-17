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

  # --- AI answer draft ---------------------------------------------------
  #
  # The drafter itself is stubbed: these tests are about the endpoint's gate
  # chain and its error contract, not about prompt assembly (see
  # test/unit/answer_drafter_test.rb).

  def enable_answer_drafts(project_enabled: true)
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge(
      'ai_enabled' => '1', 'ai_answer_enabled' => '1',
      'ai_api_key' => 'k', 'ai_model' => 'm', 'ai_provider' => 'openai'
    )
    ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => @project.id)
    ps.ai_answer_enabled = project_enabled
    ps.save!
    link_contact
  end

  def link_contact
    contact = HelpdeskContact.find_or_create_by!(:project_id => @project.id,
                                                 :email => 'kunde@example.com') do |c|
      c.name = 'Kunde'
    end
    info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => @issue.id)
    info.helpdesk_contact = contact
    info.save!
    contact
  end

  # Replaces AnswerDrafter#draft for the duration of the block. The drafter has
  # its own unit test; here only the endpoint's behaviour is of interest.
  def with_stubbed_draft(stub)
    klass    = RedmineExpertHelpdesk::AnswerDrafter
    original = klass.instance_method(:draft)
    klass.send(:define_method, :draft) { |*args, **kwargs| stub.call(*args, **kwargs) }
    yield
  ensure
    klass.send(:define_method, :draft, original)
  end

  def test_answer_draft_is_unavailable_while_globally_off
    link_contact
    post_content(:source => 'answer_draft')

    assert_response :unprocessable_entity
    assert json['error'].present?
  end

  def test_answer_draft_is_unavailable_when_the_project_did_not_opt_in
    enable_answer_drafts(:project_enabled => false)
    post_content(:source => 'answer_draft')

    assert_response :unprocessable_entity
  end

  # A customer-facing draft on a ticket with no customer would be unsendable
  # text that ends up saved as a public note instead.
  def test_answer_draft_needs_a_linked_customer
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge(
      'ai_enabled' => '1', 'ai_answer_enabled' => '1',
      'ai_api_key' => 'k', 'ai_model' => 'm', 'ai_provider' => 'openai'
    )
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
    post_content(:source => 'answer_draft')

    assert_response :unprocessable_entity
    assert_equal I18n.t(:error_helpdesk_ai_answer_no_contact), json['error']
  end

  def test_answer_draft_returns_the_text_and_its_sources
    enable_answer_drafts
    result = RedmineExpertHelpdesk::AnswerDrafter::Result.new(
      :content => 'Guten Tag, bitte pruefen Sie das Netzteil.',
      :omitted => 0, :truncated => false,
      :sources => [{ :issue_id => 2, :score => 0.87 }]
    )
    with_stubbed_draft(->(*_a, **_k) { result }) do
      post_content(:source => 'answer_draft', :variant => 'steps')
    end

    assert_response :success
    assert_equal 'Guten Tag, bitte pruefen Sie das Netzteil.', json['content']
    assert_equal false, json['truncated']
    assert_equal 1, json['sources'].size
    assert_equal 2, json['sources'][0]['issue_id']
    assert json['sources'][0]['url'].present?
  end

  def test_answer_draft_reports_a_missing_knowledge_base_match
    enable_answer_drafts
    with_stubbed_draft(->(*_a, **_k) { raise RedmineExpertHelpdesk::AnswerDrafter::NoGroundingError }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t(:error_helpdesk_ai_answer_no_grounding), json['error']
  end

  # The provider body carries endpoints and sometimes prompt fragments: it goes
  # to the log, never to the browser.
  # A near miss tells the agent the bar may be too high; a blank tells them the
  # case is new. The message has to distinguish them.
  def test_refusal_names_the_best_rejected_score
    enable_answer_drafts
    err = RedmineExpertHelpdesk::AnswerDrafter::NoGroundingError.new(:best_score => 0.61, :threshold => 0.65)
    with_stubbed_draft(->(*_a, **_k) { raise err }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :unprocessable_entity
    assert_includes json['error'], '61'
    assert_includes json['error'], '65'
  end

  def test_refusal_without_any_candidate_uses_the_plain_message
    enable_answer_drafts
    with_stubbed_draft(->(*_a, **_k) { raise RedmineExpertHelpdesk::AnswerDrafter::NoGroundingError }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t(:error_helpdesk_ai_answer_no_grounding), json['error']
  end

  def test_provider_failure_does_not_leak_the_response_body
    enable_answer_drafts
    err = RedmineExpertHelpdesk::AiClient::AiError.new('kaputt', 500, 'SECRET-ENDPOINT-BODY')
    with_stubbed_draft(->(*_a, **_k) { raise err }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :bad_gateway
    assert_not_includes response.body, 'SECRET-ENDPOINT-BODY'
    assert json['error'].present?
  end

  def test_transport_failure_is_reported_as_a_timeout
    enable_answer_drafts
    err = RedmineExpertHelpdesk::AiClient::TransportError.new('weg', nil, 'x')
    with_stubbed_draft(->(*_a, **_k) { raise err }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :gateway_timeout
    assert_equal I18n.t(:error_helpdesk_ai_answer_timeout), json['error']
  end

  # "We looked and found nothing" sends the agent to the answer templates;
  # "there is nothing to look in" sends an administrator to the settings.
  def test_switched_off_knowledge_base_is_not_reported_as_a_missing_match
    enable_answer_drafts
    with_stubbed_draft(->(*_a, **_k) { raise RedmineExpertHelpdesk::AnswerDrafter::KbUnavailableError }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :unprocessable_entity
    assert_equal I18n.t(:error_helpdesk_ai_answer_kb_unavailable), json['error']
    assert_not_equal I18n.t(:error_helpdesk_ai_answer_no_grounding), json['error']
  end

  def test_unreachable_knowledge_base_is_not_reported_as_a_missing_match
    enable_answer_drafts
    with_stubbed_draft(->(*_a, **_k) { raise RedmineExpertHelpdesk::KnowledgeStore::StoreError, 'weg' }) do
      post_content(:source => 'answer_draft')
    end

    assert_response :bad_gateway
    assert_equal I18n.t(:error_helpdesk_ai_answer_store_unreachable), json['error']
  end

  def test_island_advertises_the_button_only_when_the_feature_is_on
    link_contact
    get "/issues/#{@issue.id}/edit"
    assert_response :success
    assert_nil toolbar_island['aiDraft']

    enable_answer_drafts
    get "/issues/#{@issue.id}/edit"
    assert_response :success
    variants = toolbar_island['aiDraft']['variants']
    assert_equal RedmineExpertHelpdesk::AnswerDrafter::VARIANTS.keys, variants.map { |v| v['key'] }
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
