# Seeds a self-contained demo project used to generate the README screenshots.
#
#   bundle exec rails runner plugins/redmine_expert_helpdesk/scripts/seed_screenshot_demo.rb
#
# Everything it creates lives inside a single project (identifier "screenshot") and is
# removed again by scripts/teardown_screenshot_demo.rb. The script deliberately never
# touches global state: it does not write Setting.plugin_redmine_expert_helpdesk and it
# does not seed helpdesk_phishing_urls (that table mirrors the real phishing feeds).
#
# All data is synthetic — @example.com addresses and invented company names.
#
# NOTE: this writes into whatever database it is pointed at. It is meant for a disposable
# demo project; re-running it deletes and rebuilds only its own project's rows.

require 'securerandom'

IDENT      = 'screenshot'.freeze
LOGIN      = 'screenshot-demo'.freeze
SEED       = 20_260_727
TODAY      = Time.current

srand(SEED)
ActionMailer::Base.perform_deliveries = false

abort 'This script requires MySQL/MariaDB (the SLA issue-list columns use UTC_TIMESTAMP()).' unless
  ActiveRecord::Base.connection.adapter_name =~ /mysql/i

def say(msg) = puts("[seed] #{msg}")

# --- capture user -----------------------------------------------------------------

# Ephemeral account, removed again by teardown_screenshot_demo.rb. Set DEMO_PASSWORD to
# choose the password, otherwise a random one is generated and printed once below.
password = ENV['DEMO_PASSWORD'].presence || SecureRandom.alphanumeric(20)

user = User.find_by(login: LOGIN)
user ||= User.new(login: LOGIN, firstname: 'Screenshot', lastname: 'Demo',
                  mail: 'screenshot-demo@example.com', language: 'en')
user.admin             = true
user.password          = password
user.must_change_passwd = false
user.status            = User::STATUS_ACTIVE
user.save!
User.current = user
say "capture user ##{user.id} (#{user.login}) password=#{password}"

# --- project ----------------------------------------------------------------------

project = Project.find_by(identifier: IDENT)
project ||= Project.create!(name: 'Screenshot', identifier: IDENT, is_public: false,
                            description: 'Demo project used to generate the README screenshots.')
project.enabled_module_names = (project.enabled_module_names | %w[issue_tracking helpdesk])
project.save!
say "project ##{project.id} (#{project.identifier})"

# --- wipe previous run (this project only) ----------------------------------------

abort "refusing to wipe: unexpected project #{project.identifier}" unless project.identifier == IDENT

issue_ids = Issue.where(project_id: project.id).pluck(:id)
HelpdeskKbProposal.where(issue_id: issue_ids).delete_all
HelpdeskAiSummary.where(issue_id: issue_ids).delete_all
HelpdeskKnowledgeEntry.where(project_id: project.id).delete_all
HelpdeskAiRequest.where(project_id: project.id).delete_all
HelpdeskTicketInfo.where(issue_id: issue_ids).delete_all
HelpdeskMessage.where(issue_id: issue_ids).delete_all
Journal.where(journalized_type: 'Issue', journalized_id: issue_ids).delete_all
Issue.where(id: issue_ids).delete_all
HelpdeskContact.where(project_id: project.id).delete_all
HelpdeskRule.where(helpdesk_mailbox_id: HelpdeskMailbox.where(project_id: project.id).select(:id)).delete_all
HelpdeskMailbox.where(project_id: project.id).delete_all
HelpdeskSlaPriority.where(project_id: project.id).delete_all
say "cleared #{issue_ids.size} previously seeded issues"

# --- Redmine prerequisites --------------------------------------------------------

tracker  = project.trackers.first || Tracker.first
raise 'no tracker available' unless tracker
project.trackers = [tracker] if project.trackers.empty?

open_statuses = IssueStatus.where(is_closed: false).order(:position).to_a
status_new    = open_statuses.first or raise 'no open issue status'
status_wip    = open_statuses[1] || status_new
status_closed = IssueStatus.where(is_closed: true).order(:position).first or raise 'no closed issue status'

priorities = IssuePriority.active.order(:position).to_a
raise 'no issue priorities' if priorities.empty?
# Second-lowest priority is the realistic default ("Normal" in a stock Redmine); using the
# middle of the list makes almost every demo ticket look high-priority.
prio_default = priorities[1] || priorities.first

agents = [user]
say "tracker=#{tracker.name} closed_status=#{status_closed.name} priorities=#{priorities.map(&:name).join(',')}"

# --- project settings (SLA on, KB ingest OFF while seeding) -----------------------

OLDEST_DAYS = 365

ps = HelpdeskProjectSetting.find_or_initialize_by(project_id: project.id)
ps.assign_attributes(
  send_reply_by_default:   true,
  reply_subject_template:  'Re: [#{{issue.id}}] {{issue.subject}}',
  reply_status_id:         status_wip.id,
  reply_assign_to_sender:  true,
  sla_enabled:             true,
  sla_enabled_at:          TODAY - (OLDEST_DAYS + 30).days,
  sla_reaction_minutes:    120,
  sla_solution_minutes:    960,
  sla_work_days:           '1,2,3,4,5',
  sla_work_start:          '08:00',
  sla_work_end:            '17:00',
  sla_notify_enabled:      true,
  sla_notify_email:        'sla-alerts@example.com',
  ai_summary_enabled:      true,
  ai_summary_scope:        'initial_and_replies',
  ai_prompt_mode:          'extend',
  ai_attach_metadata:      true,
  ai_attach_text:          true,
  ai_include_journal:      true,
  kb_ingest_mode:          'off',      # flipped to 'manual' at the very end
  kb_proposal_display:     'both'
)
ps.save!
say 'project settings written (kb_ingest_mode=off during seeding)'

setting = HelpdeskProjectSetting.for_project(project)
bh      = RedmineExpertHelpdesk::BusinessHours.new(setting)

# --- SLA per-priority overrides (leave the default priority inheriting) -----------

overrides = { priorities.first.name => [480, 2880] }
overrides[priorities[-1].name] = [30, 240] if priorities.size > 1
overrides[priorities[-2].name] = [60, 480] if priorities.size > 3
overrides.each do |name, (r, s)|
  prio = IssuePriority.find_by(name: name) or next
  next if prio.id == prio_default.id
  hsp = HelpdeskSlaPriority.find_or_initialize_by(project_id: project.id, priority_id: prio.id)
  hsp.assign_attributes(reaction_minutes: r, solution_minutes: s)
  hsp.save!
end
say "sla priority overrides: #{HelpdeskSlaPriority.where(project_id: project.id).count}"

# --- mailbox ----------------------------------------------------------------------

mailbox = HelpdeskMailbox.find_or_initialize_by(mailbox_address: 'support@example.com')
mailbox.assign_attributes(
  project:            project,
  enabled:            true,
  source_folder:      'Inbox',
  processed_folder:   'Processed',
  skipped_folder:     'Skipped',
  failed_folder:      'Failed',
  default_tracker_id: tracker.id,
  default_priority_id: prio_default.id,
  default_status_id:  status_new.id,
  unknown_user_mode:  'accept',
  footer_mode:        'inherit',
  reply_transport:    'graph',
  autoresponder_enabled: true,
  auto_reply_filter_enabled: true,
  reopen_status_id:   status_wip.id,
  reopen_max_age_days: 14,
  last_fetched_at:    TODAY - 12.minutes
)
mailbox.save!
say "mailbox ##{mailbox.id} (#{mailbox.mailbox_address})"

# --- contacts ---------------------------------------------------------------------

COMPANIES = [
  'Nordwind Logistics', 'Baumann Elektro', 'Seehafen Spedition', 'Kranich Medien',
  'Weber Maschinenbau', 'Alpin Reisen', 'Lindner Immobilien', 'Fischer Catering',
  'Volt Energie', 'Brunner Apotheken', 'Stadtwerke Kirchdorf', 'Hansa Versicherung',
  'Bergmann Bau', 'Orbit Software', 'Kessler Textil'
].freeze

FIRST = %w[Anna Jonas Mia Lukas Sofia Ben Emma Paul Lena Finn Clara Noah Ida Elias Marie
           Tim Nele Jan Lea Max Hanna Leon Julia Erik Sara].freeze
LAST  = %w[Berger Hoffmann Krause Neumann Schmitt Vogel Baumann Winkler Frank Ludwig
           Roth Sommer Engel Haas Peters Kuhn Lang Wolff Simon Arnold].freeze

contacts = []
45.times do |i|
  first   = FIRST[i % FIRST.size]
  last    = LAST[(i * 7) % LAST.size]
  company = COMPANIES[i % COMPANIES.size]
  slug    = "#{first}.#{last}".downcase
  c = HelpdeskContact.create!(
    project: project,
    email:   "#{slug}#{i}@example.com",
    name:    "#{first} #{last}",
    company: (i % 9 == 4 ? nil : company),
    phone:   (i % 7 == 3 ? nil : format('+49 30 %07d', 1_000_000 + i * 4321)),
    notes:   (i % 11 == 2 ? 'Key account — always CC the account manager.' : nil)
  )
  contacts << c
end
say "contacts: #{contacts.size}"

# --- issues, ticket infos, messages ------------------------------------------------

SUBJECTS = [
  'Login fails after password reset', 'Invoice %<n>d is missing from the portal',
  'VPN connection drops every few minutes', 'Cannot upload attachments larger than 10 MB',
  'Please add a new user account', 'Printer in room %<n>d is offline',
  'Order %<n>d shipped to the wrong address', 'Export to CSV returns an empty file',
  'Two-factor codes arrive too late', 'Mailbox quota exceeded warning',
  'Request: additional licence seats', 'Dashboard shows outdated figures',
  'Password reset mail never arrives', 'Mobile app crashes on start',
  'Delivery note %<n>d has wrong quantities', 'Please cancel subscription',
  'Scanner not recognised after update', 'Access to the shared drive missing',
  'Duplicate invoice received', 'Report scheduling stopped working'
].freeze

BODIES = [
  "Hello,\n\nsince this morning the problem described above occurs reproducibly. " \
  "Restarting did not help. Could you please take a look?\n\nBest regards",
  "Good morning,\n\nwe noticed this yesterday afternoon. It affects two of our " \
  "colleagues, the others are fine.\n\nThanks in advance",
  "Hi,\n\ncould you check this please? It is blocking our daily routine.\n\nKind regards"
].freeze

REPLIES = [
  'Thanks for reaching out — we are looking into it and will get back to you shortly.',
  'We could reproduce the issue and forwarded it to our second-level team.',
  'A fix has been deployed. Could you please confirm that it works on your side?',
  'Your account has been updated as requested.'
].freeze

# ActiveRecord's update_columns does not persist a model's timestamp columns
# (created_on / updated_on on Issue and Journal, created_at / updated_at on the
# plugin's own tables). update_all does. Everything that backdates a record goes
# through these two helpers.
def backdate_issue!(issue, attrs)
  Issue.where(id: issue.id).update_all(attrs)
end

def backdate!(klass, id, attrs)
  klass.where(id: id).update_all(attrs)
end

# Places a timestamp inside working hours, bimodal around 09-11 and 14-16.
def business_moment(day)
  hour = rand < 0.55 ? [9, 10, 11].sample : [14, 15, 16].sample
  day.change(hour: hour, min: rand(0..59), sec: rand(0..59))
end

def workday_back(days_ago)
  d = (Time.current - days_ago.days)
  d -= 1.day while [6, 7].include?(d.to_date.cwday)
  d
end

ISSUE_COUNT = 220
OPEN_COUNT  = 40
issues = []

# Open tickets are seeded last and deliberately recent: an open ticket from six months
# ago would have a long-expired clock, so every one of them would render as breached.
# These offsets give a believable running / warning / breached spread instead.
OPEN_AGES = [25.minutes, 70.minutes, 100.minutes, 4.hours, 9.hours,
             1.day, 2.days, 4.days].freeze

ISSUE_COUNT.times do |i|
  open_slot = i >= (ISSUE_COUNT - OPEN_COUNT)

  if open_slot
    created  = TODAY - OPEN_AGES[i % OPEN_AGES.size]
  else
    # Denser in the recent 60 days, but spread across a full year so the default
    # last_12_months range on both dashboards is populated.
    days_ago = rand < 0.35 ? rand(1..60) : rand(61..OLDEST_DAYS)
    created  = business_moment(workday_back(days_ago))
  end

  contact = contacts[rand(contacts.size)]
  prio    = rand < 0.72 ? prio_default : priorities[rand(priorities.size)]
  subject = format(SUBJECTS[i % SUBJECTS.size], n: 1000 + rand(9000))

  issue = Issue.new(project: project, tracker: tracker, author: user,
                    subject: subject, description: BODIES[i % BODIES.size],
                    status: status_new, priority: prio, assigned_to: agents.sample)
  issue.save!
  # NOTE: update_columns silently drops created_on/updated_on here (Rails treats them as
  # the model's timestamp columns), while ordinary columns like closed_on do persist.
  # update_all writes them reliably — see backdate! below.
  backdate_issue!(issue, created_on: created, updated_on: created)
  issue.reload

  targets    = RedmineExpertHelpdesk::Sla.targets_for(issue, setting)
  target_r   = targets[:reaction].to_i
  target_s   = targets[:solution].to_i

  closed = !open_slot

  info = HelpdeskTicketInfo.find_or_initialize_by(issue_id: issue.id)
  info.helpdesk_contact = contact
  info.helpdesk_mailbox = mailbox

  if closed
    # Reaction: mostly met, some breached. Derive the timestamp through the same
    # BusinessHours#due_at the deadline uses, so the Ruby and SQL paths agree.
    if rand < 0.10
      react_min = nil                                   # no recorded first response
    elsif rand < 0.84
      react_min = rand(5..[target_r - 5, 6].max)
    else
      react_min = (target_r * (1.2 + rand * 1.8)).to_i
    end

    sol_min = rand < 0.78 ? rand(30..[(target_s * 0.9).to_i, 60].max)
                          : (target_s * (1.1 + rand * 1.4)).to_i

    closed_at = bh.due_at(created, sol_min) || (created + sol_min.minutes)
    closed_at = TODAY - 1.hour if closed_at > TODAY

    if react_min
      info.first_response_at         = bh.due_at(created, react_min) || (created + react_min.minutes)
      info.reaction_business_minutes = react_min
    end
    info.solution_business_minutes = sol_min

    backdate_issue!(issue, status_id: status_closed.id, closed_on: closed_at, updated_on: closed_at)
  else
    # Open tickets: leave a believable spread of running / warning / breached clocks.
    if rand < 0.55
      react_min = rand(5..[target_r - 5, 6].max)
      info.first_response_at         = bh.due_at(created, react_min) || (created + react_min.minutes)
      info.reaction_business_minutes = react_min
    end
    # Mix the open statuses so the ticket list is not a wall of one value.
    open_status = i.even? ? status_wip : status_new
    backdate_issue!(issue, status_id: open_status.id, updated_on: created + 1.hour)
  end

  info.save!
  issue.reload
  RedmineExpertHelpdesk::Sla.refresh_deadlines!(issue)

  # Inbound mail — drives the Kunde column, the contacts tab counters and the
  # busiest-hour / busiest-weekday charts.
  HelpdeskMessage.create!(
    issue: issue, helpdesk_contact: contact, helpdesk_mailbox: mailbox,
    direction: 'in', sent_at: created, subject: subject,
    message_id: "<#{SecureRandom.hex(12)}@example.com>",
    recipient_to: mailbox.mailbox_address
  )

  # Outbound replies, each attached to a real journal note.
  reply_count = closed ? rand(1..3) : rand(0..2)
  reply_count.times do |r|
    at = (info.first_response_at || created) + (r * rand(2..20)).hours
    at = TODAY - 30.minutes if at > TODAY
    j = Journal.create!(journalized: issue, user: agents.sample, notes: REPLIES[r % REPLIES.size])
    backdate!(Journal, j.id, created_on: at, updated_on: at)
    HelpdeskMessage.create!(
      issue: issue, helpdesk_contact: contact, helpdesk_mailbox: mailbox,
      direction: 'out', journal_id: j.id, sent_at: at,
      subject: "Re: #{subject}",
      message_id: "<#{SecureRandom.hex(12)}@example.com>",
      recipient_to: contact.email
    )
  end

  issues << issue
  say "issues #{i + 1}/#{ISSUE_COUNT}" if ((i + 1) % 50).zero?
end

closed_issues = issues.select { |i| i.reload.closed? }
say "issues: #{issues.size} (#{closed_issues.size} closed)"

# --- AI summaries on hero tickets --------------------------------------------------

AI_MODELS = [
  ['openai',    'gpt-4o-mini'],
  ['anthropic', 'claude-3-5-haiku'],
  ['openai',    'text-embedding-3-small']
].freeze

hero = issues.sample(30)
hero.each do |issue|
  at = issue.created_on + 6.minutes
  j  = Journal.create!(journalized: issue, user: user, private_notes: true,
                       notes: "**AI summary**\n\n" \
                              "* Customer reports: #{issue.subject.downcase}\n" \
                              "* Started after the latest update, reproducible\n" \
                              "* Affects a single workstation, others unaffected\n" \
                              "* Suggested next step: check the client configuration")
  backdate!(Journal, j.id, created_on: at, updated_on: at)
  provider, model = AI_MODELS[rand(2)]
  HelpdeskAiSummary.create!(issue: issue, journal_id: j.id, provider: provider, model: model,
                            input_tokens: 1500 + rand(2500), output_tokens: 150 + rand(350))
end
say "ai summaries: #{hero.size}"

# --- knowledge base entries + proposals --------------------------------------------

KB_SOLUTIONS = [
  'Reset the local client configuration and re-run the setup assistant. If the problem ' \
  'persists, renew the device certificate.',
  'The mailbox had exceeded its storage quota. Archiving messages older than twelve months ' \
  'and emptying the deleted-items folder resolved it.',
  'A stale session token was cached. Signing out on all devices and signing back in restored ' \
  'access immediately.',
  'The print spooler service had stopped. Restarting it on the print server and re-adding the ' \
  'queue on the client fixed the issue.',
  'The export ran into the 10 MB attachment limit. Splitting the report into monthly batches ' \
  'produced complete files.',
  'DNS resolution for the VPN gateway was failing intermittently. Switching the client to the ' \
  'secondary resolver stabilised the connection.',
  'The licence pool was exhausted. Two seats were reassigned from deactivated accounts and the ' \
  'user could sign in again.'
].freeze

kb_sources = closed_issues.sample([closed_issues.size, 95].min)
kb_sources.each_with_index do |issue, idx|
  status = case idx % 10
           when 0, 1 then 'pending'
           when 2    then 'skipped'
           else 'approved'
           end
  e = HelpdeskKnowledgeEntry.create!(
    project_id: project.id, issue_id: issue.id, status: status,
    problem:  issue.subject,
    solution: KB_SOLUTIONS[idx % KB_SOLUTIONS.size],
    embed_model: 'text-embedding-3-small', point_id: SecureRandom.uuid,
    input_tokens: 900 + rand(600), output_tokens: 60 + rand(80)
  )
  at = issue.closed_on || issue.created_on
  backdate!(HelpdeskKnowledgeEntry, e.id, created_at: at, updated_at: at)
end
say "knowledge entries: #{kb_sources.size}"

approved = HelpdeskKnowledgeEntry.where(project_id: project.id, status: 'approved').to_a
hero.first(20).each do |issue|
  approved.reject { |e| e.issue_id == issue.id }.sample(2).each_with_index do |src, k|
    HelpdeskKbProposal.create!(
      issue_id: issue.id, source_issue_id: src.issue_id,
      score: (0.88 - k * 0.13).round(2),
      problem: src.problem, solution: src.solution
    )
  end
end
say "kb proposals: #{HelpdeskKbProposal.where(issue_id: issues.map(&:id)).count}"

# --- AI request log ------------------------------------------------------------------

TYPE_MIX = ([:summary] * 45 + [:kb_embed] * 25 + [:kb_retrieve] * 22 + [:kb_extract] * 8).freeze

rows = []
1400.times do
  days_ago = rand < 0.35 ? rand(0..60) : rand(61..OLDEST_DAYS)
  at   = business_moment(workday_back(days_ago))
  type = TYPE_MIX.sample.to_s
  provider, model = type.start_with?('kb_e') && rand < 0.7 ? AI_MODELS[2] : AI_MODELS[rand(2)]
  ok   = rand > 0.04

  tokens_in, tokens_out, dur =
    case type
    when 'summary'     then [1500 + rand(2500), 150 + rand(350), 400 + rand(4100)]
    when 'kb_extract'  then [2000 + rand(4000), 200 + rand(200), 800 + rand(3500)]
    else                    [200 + rand(700),   0,               60 + rand(340)]
    end

  rows << {
    request_type: type, provider: provider, model: model,
    project_id: project.id, issue_id: issues.sample.id,
    input_tokens: tokens_in, output_tokens: tokens_out, duration_ms: dur,
    success: ok,
    error_class: ok ? nil : 'RedmineExpertHelpdesk::AiClient::AiError',
    http_status: ok ? nil : [429, 500, 503].sample,
    created_at: at
  }
end
rows.each_slice(500) { |slice| HelpdeskAiRequest.insert_all(slice) }
say "ai requests: #{HelpdeskAiRequest.where(project_id: project.id).count}"

# --- finally enable KB ingest (kept off above so no job fires during seeding) -------

ps.reload.update!(kb_ingest_mode: 'manual')

say 'done.'
say "open http://localhost:3000/projects/#{project.identifier} as #{LOGIN}"
