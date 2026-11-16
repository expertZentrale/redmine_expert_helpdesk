require File.expand_path('../../test_helper', __FILE__)

# Mail log lookup by Message-ID (GET /helpdesk/messages). Rows hold either
# spelling of a Message-ID, and a caller may send either; both must meet.
class HelpdeskMessagesApiTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    Setting.rest_api_enabled = '1'
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    @issue = Issue.find(1)
    HelpdeskMessage.delete_all
    # Incoming mail is stored bare, a reply through the mailbox with brackets.
    @incoming = HelpdeskMessage.create!(:issue => @issue, :direction => 'in',
                                        :message_id => 'customer-1@mail.example.com', :subject => 'Drucker')
    @reply = HelpdeskMessage.create!(:issue => @issue, :direction => 'out',
                                     :message_id => '<reply-1@helpdesk.example.com>', :subject => 'Re: Drucker')
    @key = User.find(2).api_key # jsmith, Manager in project 1
  end

  def teardown
    Setting.rest_api_enabled = '0'
  end

  def auth(user_id = 2)
    { 'X-Redmine-API-Key' => User.find(user_id).api_key }
  end

  def json
    ActiveSupport::JSON.decode(@response.body)
  end

  def lookup(query, headers = auth)
    get "/helpdesk/messages.json?#{query}", :headers => headers
  end

  def found_ids
    json['helpdesk_messages'].map { |m| m['id'] }
  end

  def test_requires_authentication
    lookup('message_id=customer-1@mail.example.com', {})
    assert_response :unauthorized
  end

  def test_finds_a_bare_row_with_either_spelling
    lookup('message_id=customer-1@mail.example.com')
    assert_response :success
    assert_equal [@incoming.id], found_ids

    lookup("message_id=#{CGI.escape('<customer-1@mail.example.com>')}")
    assert_equal [@incoming.id], found_ids
  end

  def test_finds_a_bracketed_row_with_either_spelling
    lookup('message_id=reply-1@helpdesk.example.com')
    assert_equal [@reply.id], found_ids

    lookup("message_id=#{CGI.escape('<reply-1@helpdesk.example.com>')}")
    assert_equal [@reply.id], found_ids
  end

  def test_returns_message_ticket_and_project
    lookup("message_id=#{CGI.escape('<reply-1@helpdesk.example.com>')}")
    row = json['helpdesk_messages'].first
    assert_equal 'reply-1@helpdesk.example.com', row['message_id'], 'always bare'
    assert_equal 'out', row['direction']
    assert_equal 'Re: Drucker', row['subject']
    assert_equal({ 'id' => @issue.id, 'subject' => @issue.subject }, row['issue'])
    assert_equal({ 'id' => @project.id, 'name' => @project.name }, row['project'])
    assert_equal 1, json['total_count']
  end

  def test_several_ids_comma_separated_or_as_array
    lookup('message_id=customer-1@mail.example.com,reply-1@helpdesk.example.com,unknown@example.com')
    assert_equal [@incoming.id, @reply.id], found_ids
    assert_equal 2, json['total_count']

    lookup('message_id[]=customer-1@mail.example.com&message_id[]=reply-1@helpdesk.example.com')
    assert_equal [@incoming.id, @reply.id], found_ids
  end

  def test_unknown_id_is_an_empty_list
    lookup('message_id=unknown@example.com')
    assert_response :success
    assert_equal [], found_ids
    assert_equal 0, json['total_count']
  end

  def test_message_id_is_required
    lookup('message_id=')
    assert_response :unprocessable_entity
    get '/helpdesk/messages.json', :headers => auth
    assert_response :unprocessable_entity
  end

  def test_too_many_ids_are_refused
    ids = (1..(HelpdeskMessagesApiController::MAX_IDS + 1)).map { |i| "m#{i}@example.com" }
    lookup("message_id=#{ids.join(',')}")
    assert_response :unprocessable_entity
  end

  def test_hidden_when_the_issue_is_not_visible
    Role.find(1).remove_permission!(:view_issues)
    lookup('message_id=customer-1@mail.example.com')
    assert_response :success
    assert_equal [], found_ids
  end

  def test_hidden_when_the_helpdesk_module_is_off
    @project.disable_module!(:helpdesk)
    lookup('message_id=customer-1@mail.example.com')
    assert_equal [], found_ids
  end

  def test_project_id_narrows_the_lookup
    other = Project.find(2)
    other.enable_module!(:helpdesk)
    elsewhere = HelpdeskMessage.create!(:issue => Issue.where(:project_id => other.id).first!, :direction => 'in',
                                        :message_id => 'customer-1@mail.example.com')

    # Admin sees both projects; the same mail went into both.
    lookup('message_id=customer-1@mail.example.com', auth(1))
    assert_equal [@incoming.id, elsewhere.id], found_ids

    lookup("message_id=customer-1@mail.example.com&project_id=#{other.identifier}", auth(1))
    assert_equal [elsewhere.id], found_ids
  end

  def test_unknown_project_is_not_found
    lookup('message_id=customer-1@mail.example.com&project_id=does-not-exist')
    assert_response :not_found
  end

  def test_xml
    get '/helpdesk/messages.xml?message_id=customer-1@mail.example.com', :headers => auth
    assert_response :success
    assert_select 'helpdesk_messages[type=array] message message_id', :text => 'customer-1@mail.example.com'
  end
end
