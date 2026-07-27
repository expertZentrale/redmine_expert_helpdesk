require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Fusszeilen-Logik (zentrale Signatur vs. Postfach-Fusszeile).
class HelpdeskMailboxTest < ActiveSupport::TestCase
  GLOBAL = "--\nexample.com Zentrale".freeze
  LOCAL  = "Team Nord\nTel. 0123".freeze

  def setup
    @previous_settings = Setting.plugin_redmine_expert_helpdesk
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @previous_settings
  end

  def test_inherit_uses_global_footer
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'inherit', :reply_footer => LOCAL)
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_inherit_falls_back_to_mailbox_footer_without_global
    set_global_footer('')
    mailbox = HelpdeskMailbox.new(:footer_mode => 'inherit', :reply_footer => LOCAL)
    assert_equal LOCAL, mailbox.effective_footer_template
  end

  def test_blank_mode_behaves_like_inherit
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => nil, :reply_footer => LOCAL)
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_override_uses_mailbox_footer_only
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'override', :reply_footer => LOCAL)
    assert_equal LOCAL, mailbox.effective_footer_template
  end

  def test_prepend_combines_mailbox_and_global
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'prepend', :reply_footer => LOCAL)
    assert_equal "#{LOCAL}\n\n#{GLOBAL}", mailbox.effective_footer_template
  end

  def test_prepend_with_blank_mailbox_footer_uses_global_only
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'prepend', :reply_footer => '')
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_footer_mode_validation
    mailbox = HelpdeskMailbox.new(:footer_mode => 'kaputt')
    mailbox.valid?
    assert_not_empty mailbox.errors[:footer_mode]

    HelpdeskMailbox::FOOTER_MODES.each do |mode|
      mailbox = HelpdeskMailbox.new(:footer_mode => mode)
      mailbox.valid?
      assert_empty mailbox.errors[:footer_mode], "#{mode} sollte gueltig sein"
    end
  end

  private

  def set_global_footer(value)
    Setting.plugin_redmine_expert_helpdesk =
      (Setting.plugin_redmine_expert_helpdesk || {}).merge('global_footer' => value)
  end
end
