require File.expand_path('../../test_helper', __FILE__)

# Colours of the customer-facing block in the ticket edit form: validation and the
# project -> central -> constant chain.
class ReplyBoxTest < ActiveSupport::TestCase
  fixtures :all

  RB = RedmineExpertHelpdesk::ReplyBox

  def setup
    @project = Project.find(1)
    @settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @settings_snapshot if @settings_snapshot
  end

  # -----------------------------------------------------------------------
  # Validation
  # -----------------------------------------------------------------------

  def test_hex_colours_are_accepted
    assert_equal '#abc', RB.color('#abc', '#fff')
    assert_equal '#aabbcc', RB.color('#aabbcc', '#fff')
    assert_equal '#aabbcc', RB.color('  #AABBCC  ', '#fff'), 'trimmed and downcased'
  end

  # These values are interpolated into a stylesheet, so anything that is not plainly a
  # colour is discarded rather than escaped.
  def test_anything_that_is_not_a_hex_colour_falls_back
    [
      'red', 'rgb(1,2,3)', '#xyz', '#ab', '#abcd', 'abc', '',
      'url(https://evil.example/x)',
      "#fff; } body { display: none } .x {",
      "#fff</style><script>alert(1)</script>"
    ].each do |bad|
      assert_equal '#fff', RB.color(bad, '#fff'), "#{bad.inspect} must not reach CSS"
    end
  end

  def test_nil_falls_back
    assert_equal RB::DEFAULT_BOX_COLOR, RB.box_color(nil)
    assert_equal RB::DEFAULT_HAZARD_COLOR, RB.hazard_color(nil)
  end

  # -----------------------------------------------------------------------
  # project -> central -> constant
  # -----------------------------------------------------------------------

  def test_defaults_apply_without_any_configuration
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({})

    assert_equal RB::DEFAULT_BOX_COLOR, setting.effective_reply_box_color
    assert_equal RB::DEFAULT_HAZARD_COLOR, setting.effective_reply_hazard_color
  end

  def test_the_central_value_is_used_when_the_project_has_none
    central(:reply_box_color => '#112233', :reply_hazard_color => '#445566')

    assert_equal '#112233', setting.effective_reply_box_color
    assert_equal '#445566', setting.effective_reply_hazard_color
  end

  def test_the_project_overrides_the_central_value
    central(:reply_box_color => '#112233', :reply_hazard_color => '#445566')
    setting.update!(:reply_box_color => '#aabbcc', :reply_hazard_color => '#ddeeff')

    assert_equal '#aabbcc', setting.reload.effective_reply_box_color
    assert_equal '#ddeeff', setting.effective_reply_hazard_color
  end

  def test_an_emptied_project_value_falls_back_to_the_central_one
    central(:reply_box_color => '#112233')
    setting.update!(:reply_box_color => '#aabbcc')
    setting.update!(:reply_box_color => nil)

    assert_equal '#112233', setting.reload.effective_reply_box_color
  end

  # A malformed central value must not reach the stylesheet either.
  def test_a_malformed_central_value_falls_back_to_the_constant
    central(:reply_box_color => 'red; } body { display:none')

    assert_equal RB::DEFAULT_BOX_COLOR, setting.effective_reply_box_color
  end

  def test_the_model_rejects_a_non_colour
    record = setting
    record.reply_box_color = 'red'
    assert_not record.valid?
    assert record.errors[:reply_box_color].present?

    record.reply_box_color = '#a1b2c3'
    assert record.valid?
  end

  def test_blank_is_valid_because_it_means_inherit
    record = setting
    record.reply_box_color = ''
    record.reply_hazard_color = nil
    assert record.valid?
  end

  private

  def setting
    @setting ||= HelpdeskProjectSetting.find_or_create_by!(:project_id => @project.id)
  end

  def central(values)
    current = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk = current.merge(values.stringify_keys)
  end
end
