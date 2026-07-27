# Removes everything scripts/seed_screenshot_demo.rb created.
#
#   bundle exec rails runner plugins/redmine_expert_helpdesk/scripts/teardown_screenshot_demo.rb
#
# Deletes only rows belonging to the "screenshot" project, then the project and the
# capture user. Global state is never touched: Setting.plugin_redmine_expert_helpdesk
# and helpdesk_phishing_urls are left exactly as they were.
#
# Pass KEEP_USER=1 to leave the capture user in place.

IDENT = 'screenshot'.freeze
LOGIN = 'screenshot-demo'.freeze

def say(msg) = puts("[teardown] #{msg}")

project = Project.find_by(identifier: IDENT)

if project.nil?
  say "no project with identifier '#{IDENT}' — nothing to do"
else
  # Guard: never let this run against anything but the demo project.
  abort "refusing: project ##{project.id} has identifier '#{project.identifier}'" unless
    project.identifier == IDENT

  issue_ids = Issue.where(project_id: project.id).pluck(:id)
  say "project ##{project.id}, #{issue_ids.size} issues"

  # Order matters: children before parents. delete_all rather than destroy_all so the
  # after_save hooks in issue_patch.rb (SLA refresh, KB ingest enqueue) never fire.
  counts = {
    'kb proposals'      => HelpdeskKbProposal.where(issue_id: issue_ids).delete_all,
    'ai summaries'      => HelpdeskAiSummary.where(issue_id: issue_ids).delete_all,
    'knowledge entries' => HelpdeskKnowledgeEntry.where(project_id: project.id).delete_all,
    'ai requests'       => HelpdeskAiRequest.where(project_id: project.id).delete_all,
    'ticket infos'      => HelpdeskTicketInfo.where(issue_id: issue_ids).delete_all,
    'messages'          => HelpdeskMessage.where(issue_id: issue_ids).delete_all,
    'journal details'   => JournalDetail.where(journal_id: Journal.where(journalized_type: 'Issue', journalized_id: issue_ids).select(:id)).delete_all,
    'journals'          => Journal.where(journalized_type: 'Issue', journalized_id: issue_ids).delete_all,
    'issues'            => Issue.where(id: issue_ids).delete_all,
    'contacts'          => HelpdeskContact.where(project_id: project.id).delete_all,
    'rules'             => HelpdeskRule.where(helpdesk_mailbox_id: HelpdeskMailbox.where(project_id: project.id).select(:id)).delete_all,
    'mailboxes'         => HelpdeskMailbox.where(project_id: project.id).delete_all,
    'sla priorities'    => HelpdeskSlaPriority.where(project_id: project.id).delete_all,
    'project setting'   => HelpdeskProjectSetting.where(project_id: project.id).delete_all
  }
  counts.each { |label, n| say format('%-18s %d', label, n) }

  project.destroy
  say "project '#{IDENT}' destroyed"
end

unless ENV['KEEP_USER'] == '1'
  user = User.find_by(login: LOGIN)
  if user
    Member.where(user_id: user.id).delete_all
    user.destroy
    say "capture user '#{LOGIN}' destroyed"
  end
end

say "remaining projects: #{Project.count}"
say 'done.'
