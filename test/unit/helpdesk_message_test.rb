require File.expand_path('../../test_helper', __FILE__)

class HelpdeskMessageTest < ActiveSupport::TestCase
  fixtures :all

  # -----------------------------------------------------------------------
  # Constants
  # -----------------------------------------------------------------------

  def test_directions_constant_contains_all_expected_values
    assert_includes HelpdeskMessage::DIRECTIONS, 'in'
    assert_includes HelpdeskMessage::DIRECTIONS, 'out'
    assert_includes HelpdeskMessage::DIRECTIONS, 'init'
    assert_equal 3, HelpdeskMessage::DIRECTIONS.size
  end

  # -----------------------------------------------------------------------
  # Validations (in-memory, no DB write needed)
  # -----------------------------------------------------------------------

  def test_direction_must_be_valid
    msg = HelpdeskMessage.new(:issue => Issue.first, :direction => 'unknown')
    msg.valid?
    assert msg.errors[:direction].any?
  end

  def test_all_defined_directions_pass_direction_validation
    HelpdeskMessage::DIRECTIONS.each do |dir|
      msg = HelpdeskMessage.new(:issue => Issue.first, :direction => dir)
      msg.valid?
      assert_not msg.errors[:direction].any?, "direction '#{dir}' should be valid"
    end
  end

  def test_issue_is_required
    msg = HelpdeskMessage.new(:direction => 'in')
    msg.valid?
    assert msg.errors[:issue].any?
  end

  # -----------------------------------------------------------------------
  # Scopes
  # -----------------------------------------------------------------------

  def test_incoming_scope_includes_inbound_messages
    issue = Issue.first
    msg   = HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    assert_includes HelpdeskMessage.incoming, msg
  end

  def test_incoming_scope_excludes_outbound_and_init_messages
    issue    = Issue.first
    msg_out  = HelpdeskMessage.create!(:issue => issue, :direction => 'out')
    msg_init = HelpdeskMessage.create!(:issue => issue, :direction => 'init')
    assert_not_includes HelpdeskMessage.incoming, msg_out
    assert_not_includes HelpdeskMessage.incoming, msg_init
  end

  def test_outgoing_scope_includes_outbound_messages
    issue = Issue.first
    msg   = HelpdeskMessage.create!(:issue => issue, :direction => 'out')
    assert_includes HelpdeskMessage.outgoing, msg
  end

  def test_outgoing_scope_excludes_inbound_and_init_messages
    issue    = Issue.first
    msg_in   = HelpdeskMessage.create!(:issue => issue, :direction => 'in')
    msg_init = HelpdeskMessage.create!(:issue => issue, :direction => 'init')
    assert_not_includes HelpdeskMessage.outgoing, msg_in
    assert_not_includes HelpdeskMessage.outgoing, msg_init
  end
end
