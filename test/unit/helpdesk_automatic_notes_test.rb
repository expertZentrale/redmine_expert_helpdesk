require File.expand_path('../../test_helper', __FILE__)

# The plugin writes several notes on a ticket by itself: the autoresponder, the
# phishing warning, the AI summary and the completeness follow-up. None of them is
# an agent doing something, so none may count as one.
#
# Two things are at stake, and they fail through different code paths:
# - the SLA reaction clock (Sla.record_first_response!)
# - the "awaiting agent" flag (JournalPatch#helpdesk_clear_awaiting_agent)
class HelpdeskAutomaticNotesTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :issue_statuses, :users, :trackers, :enumerations,
           :roles, :members, :member_roles, :enabled_modules

  def setup
    @issue = Issue.generate!(:project_id => 1, :subject => 'automatic notes')
    @issue.project.enable_module!(:helpdesk)
    @ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => @issue.project_id)
    @ps.assign_attributes(:sla_enabled => true, :sla_reaction_minutes => 60,
                          :sla_solution_minutes => 480, :sla_work_days => '1,2,3,4,5',
                          :sla_work_start => '08:00', :sla_work_end => '17:00')
    @ps.save!
    HelpdeskTicketInfo.find_or_initialize_by(:issue_id => @issue.id).save!
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply')
  end

  # Every automatic note the plugin writes, in the shape it writes it.
  def automatic_note(private_note: false)
    Journal.create!(:journalized => @issue, :user => User.anonymous,
                    :notes => 'automatisch erzeugt', :private_notes => private_note)
  end

  def info
    HelpdeskTicketInfo.for_issue(@issue).reload
  end

  # --- The awaiting-agent flag ---

  def test_automatic_note_does_not_clear_the_awaiting_flag
    assert_not_nil info.awaiting_agent_since, 'precondition: the ticket waits for an agent'
    automatic_note
    assert_not_nil info.awaiting_agent_since,
                   'an automatic note must not count as an agent answering'
  end

  # The permission check alone was not enough: a project may grant
  # send_helpdesk_reply to the Anonymous role, and then the phishing note would
  # clear the flag that was set moments earlier during the same fetch.
  def test_automatic_note_is_ignored_even_when_anonymous_may_reply
    Role.anonymous.add_permission!(:send_helpdesk_reply)
    automatic_note
    assert_not_nil info.awaiting_agent_since,
                   'anonymous is the plugin, never an agent - permission or not'
  end

  # The counterpart: a real agent answering must still clear it.
  def test_agent_note_still_clears_the_flag
    Role.find(1).add_permission!(:send_helpdesk_reply)
    Journal.create!(:journalized => @issue, :user => User.find(2),
                    :notes => 'Antwort an den Kunden', :private_notes => false)
    assert_nil info.awaiting_agent_since, 'an agent reply must still clear the flag'
  end

  def test_private_automatic_note_does_not_clear_the_flag
    automatic_note(:private_note => true)
    assert_not_nil info.awaiting_agent_since
  end

  # --- The SLA reaction clock ---

  # record_first_response! hangs off controller_issues_edit_after_save, so a note
  # created outside a controller can never reach it. Pinned here so a future move
  # of that call to a model callback cannot silently break the guarantee.
  def test_automatic_note_does_not_stop_the_reaction_clock
    automatic_note
    assert_nil info.first_response_at,
               'an automatic note must not count as the first response'
  end

  def test_private_automatic_note_does_not_stop_the_reaction_clock
    automatic_note(:private_note => true)
    assert_nil info.first_response_at
  end
end
