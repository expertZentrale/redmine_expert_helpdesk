require File.expand_path('../../test_helper', __FILE__)

# A Graph failure only ever showed its HTTP status, so a 403 could not be told
# apart from another 403 - "the RBAC scope does not cover this mailbox" and "the
# mailbox is on-premises/inactive" look identical, and need opposite fixes.
class GraphClientErrorTest < ActiveSupport::TestCase
  Client = RedmineExpertHelpdesk::GraphClient

  def detail(body)
    Client.new({}).send(:graph_error_detail, body)
  end

  def test_access_denied_names_the_graph_error_code
    body = { 'error' => { 'code'    => 'ErrorAccessDenied',
                          'message' => 'Access is denied. Check credentials and try again.' } }.to_json

    assert_equal ' - ErrorAccessDenied: Access is denied. Check credentials and try again.', detail(body)
  end

  # The other 403: nothing to do with permissions, so no amount of scope
  # fiddling fixes it. Telling them apart is the whole point.
  def test_mailbox_not_enabled_names_the_graph_error_code
    body = { 'error' => { 'code'    => 'MailboxNotEnabledForRESTAPI',
                          'message' => 'The mailbox is either inactive, soft-deleted, or is hosted on-premise.' } }.to_json

    assert_equal ' - MailboxNotEnabledForRESTAPI: The mailbox is either inactive, soft-deleted, ' \
                 'or is hosted on-premise.', detail(body)
  end

  def test_message_without_a_code_is_still_reported
    assert_equal ' - boom', detail({ 'error' => { 'message' => 'boom' } }.to_json)
  end

  # A gateway or proxy can answer with HTML, and a body may be missing entirely.
  # None of that may turn a useful error into an exception of its own.
  def test_unparsable_bodies_add_nothing
    ['', nil, '<html>502 Bad Gateway</html>', '{}', '{"error":"a string, not an object"}'].each do |body|
      assert_equal '', detail(body), "expected no detail for #{body.inspect}"
    end
  end
end
