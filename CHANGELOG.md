# Changelog – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> This English changelog starts fresh on 2026-07-24. Entries predating it live only in the German
> `CHANGELOG.de.md`. From here on, every change is recorded in **both** files (EN authoritative —
> GitHub release notes are generated from this file).

## [Unreleased]

### Added

- **New tickets can be assigned to a fixed user or group per project.** Until now the plugin could
  only put a ticket on the agent who happened to answer it: a ticket arriving by mail was created
  unassigned, and the only way to route it anywhere was a mailbox rule matching subject or sender.
  Teams that work out of a shared queue — 2nd level, an on-call group, a dispatcher — had no way to
  express that at all, because nothing in the plugin could address a **group**. *Project settings →
  expert Helpdesk → Reply settings* now carries **Assign new tickets to**, a dropdown of the
  project's assignable principals split into Users and Groups, defaulting to "none" so nothing
  changes for existing projects. It is applied when incoming mail creates a ticket, and only then —
  replies never re-assign, so an agent's manual decision always stands. Two things deliberately win
  over it: an `Assigned to:` keyword in the mail body, which Redmine's own `MailHandler` has already
  honoured by the time we look, and a matching mailbox rule, which is the more specific statement.
  The option list comes from `Project#assignable_users`, the same source the issue form uses, so we
  can never offer an assignee Redmine would reject; groups therefore appear only while *Allow issue
  assignment to groups* is enabled in the Redmine settings. The configured principal is re-checked
  against that list at assignment time, so a member who later loses the role or leaves the project
  silently stops being used instead of producing invalid tickets.

- **Mailbox rules can assign to a group.** The rule action *Assign to* resolved its value against
  the project's members and could only ever find a user, which left the rules engine unable to
  express the same routing the new project default now supports. The dropdown is built from the
  project's assignable principals, groups marked as such in the label, and stores the principal id.
  Rules created before this release store a login and keep resolving unchanged — the login is still
  tried first.

### Changed

- **"Assign ticket to me after reply" only takes effect while the ticket is still unassigned.** The
  option overwrote the assignee on every single reply, so a ticket a dispatcher had just routed to
  2nd level was silently taken over by the first agent who answered — and an assignee picked in the
  very same form was discarded on send. It now claims the ticket only when nobody holds it, which is
  what the option was meant to do; existing assignments, to a user or a group, are left alone.

- **Mailbox rules assigning a ticket now use the project's assignable members** (`assignable_users`)
  instead of all members (`users`). A member whose role is not assignable could previously be set as
  assignee by a rule, which the issue form itself would refuse.

## [0.3.0] - 2026-08-13

### Added

- **Prior ticket content can be quoted into the note field with one click.** Agents answering a
  customer were copy-pasting out of the ticket history by hand, which loses the `>` prefixing mail
  clients need to fold a quote — and, worse, silently drags along whatever was selected. A
  **Quote** button now sits next to the formatting icons of the note editor with three entries:
  *Original email* quotes the ticket description (the mail `MailHandler` turned into the ticket,
  with inline images already resolved), *Complete conversation* adds every public journal note,
  and *Email conversation* adds only the notes that belong to a mail actually exchanged with the
  customer. **Private notes are excluded from all three, including for agents who are allowed to
  read them** — the text is destined for a customer, so "may the customer see it" is the only
  question that matters. The plugin's own bookkeeping notes (autoresponder sent, phishing links
  removed) are dropped as well: they are public and authored by the anonymous user, but carry no
  `HelpdeskMessage`, which is exactly what distinguishes them from a customer mail filed under the
  same user. Very long histories are capped so the note field stays editable, and the toolbar says
  so instead of truncating silently. Entries are separated by a horizontal rule, so a long history
  can be skimmed while scrolling instead of running together into one wall of quoted text.

- **Answer templates are now first-class objects, globally and per project.** Support cases repeat,
  and until now every acknowledgement, follow-up question and closing text was retyped. Templates
  live in their own table with a **Templates** button next to the Quote button; a project's own
  templates are offered first, then the global ones from *Administration → Plugins*, so a project
  can override a central wording by using the same name. The content understands the same `{{…}}`
  macros as autoresponder, header/footer and subject templates, and they are expanded **on the
  server at insertion time** — a macro needs the ticket, its customer and the acting user, none of
  which the browser has. A real table rather than a value in the plugin settings hash, because that
  hash is written atomically: two admins saving the settings page would clobber each other's
  template list, and there would be no validation, ordering or per-project rows.

- **The mailbox form's connection test can copy the whole message.** Provider errors are long and
  the status line wraps, so what is readable on screen is not necessarily what you want to paste
  into a ticket. **Copy message** puts the full text on the clipboard; where the clipboard API is
  unavailable — an internal Redmine over plain http is not a secure context — it selects the text
  instead of failing silently.

- **Embedded images of an incoming mail are now shown in the ticket instead of their `[cid:…]`
  marker.** Redmine's `MailHandler` saved every inline image as an attachment but left the
  reference the mail client had written into the body, so a signature arrived as
  `[cid:image001.png@01DD2980.37ED1560]` where the mail showed a logo. The new
  `RedmineExpertHelpdesk::InlineImages` rewrites those markers — Outlook's `[cid:…]`, Gmail's
  `[image: …]`, `<img src="cid:…">` and the textile/markdown variants — into the image syntax of
  the configured formatting (`!name.png!` resp. `![](name.png)`), pointing at the attachment that
  was just stored. Mails whose body Redmine builds from the HTML part get their `<img>` tags
  turned into the same marker beforehand, because Redmine's HTML-to-text parser drops images
  without a trace. The `.eml` archived on the ticket keeps the untouched original either way, and
  markers without a matching attachment are left alone. Can be switched off under
  *Administration → Plugins → Redmine expert Helpdesk → Embedded images*.

- **Mails sent to the customer now carry their send time in the journal header**, the same way
  received mails already did. The badge on an outgoing note ends with `HelpdeskMessage.sent_at`
  (tooltip *Sent on*), so an agent can follow the whole correspondence on one time axis instead
  of reading the outgoing side off the journal's own timestamp, which is when the note was saved
  rather than when the mail left.
- **`scripts/README.md` (+ its German mirror) documents the Microsoft 365 permission model.** How
  the tenant-wide Entra application permissions and the Exchange Online RBAC scope interact (and
  why the setup is only complete once the former are removed), plus a comparison of the four
  mailbox scope options along the axis that actually decides between them: who can onboard the
  next mailbox, and what they need in order to do it — from "an Exchange Administrator runs the
  script" (`EmailList`) to "whoever creates the shared mailbox sets one attribute"
  (`CustomAttribute`). Includes the migration path between options and a troubleshooting section.

### Changed

- **`-ListRoleAssignments` shows which mailboxes a scope actually covers**, by asking Exchange
  Online to evaluate the filter (`Get-Recipient -RecipientPreviewFilter`) rather than reading it by
  eye — the only way to answer that for a `CustomAttribute`, domain or group filter. With
  `-TestMailbox` it also reports what Exchange Online makes of one specific address, which is the
  diagnosis for a Graph 403 on a single mailbox: a 403 means the filter does not match it, so it
  will be missing from that list.
- **`-ListRoleAssignments` shows what an environment consists of.** Read-only: the app
  registration and its tags, the role assignments, and every scope they point at together with its
  recipient filter — and, for an address-list scope, the mailboxes spelled out one per line. It also
  flags role/scope combinations assigned more than once.
- **Table output is no longer truncated.** `Format-Table` sizes columns to the console, so the
  authorization test's output lost the end of a scope name (`Redmine-expert-Helpdes…`) and, on a
  narrow terminal, dropped the `ScopeType` and `InScope` columns altogether — the two that say
  whether the mailbox is actually reachable. Columns are now sized to their content and rendered at
  a width that leaves everything intact, so the output stays correct however narrow the terminal is
  and when pasted elsewhere. The confirmation details in `delete-app-registration.ps1` get the same
  treatment.
- **`-RemoveDuplicateRoleAssignments` tidies up duplicate role assignments.** Keeps one assignment
  per role and scope and removes the rest, so `Test-ServicePrincipalAuthorization` stops printing
  each role several times. Given on its own the script does only this and stops; given alongside a
  normal run the tidy-up happens as part of it, and `-WhatIf` lists what would go without removing
  anything. Assignments on different scopes are never treated as duplicates, so a DEV and a LIVE
  installation are safe from each other.
- **`scripts/setup-azure-app.ps1` can now add mailboxes to an existing setup.** The script used
  to abort as soon as an app registration with the given name existed, so onboarding one more
  project meant either tearing the whole tenant setup down and rebuilding it — which mints a new
  client secret and forces a Redmine config change — or editing the Exchange Online management
  scope by hand. It is now re-runnable end to end: an existing app registration, service
  principal, client secret, EXO service principal, management scope and role assignments are
  reused instead of duplicated, and a run with a new `-MailboxEmailList` address merges that
  address into the existing RBAC scope. Client ID and client secret stay valid, so nothing
  changes under *Administration → Plugins → Redmine expert Helpdesk*.
- **`-MailboxEmailList` is additive now.** It used to describe the complete scope; it now
  describes the addresses that must be in the scope, and the ones already there are kept. Pass
  the new `-ReplaceMailboxList` to get the old "exactly this list" behaviour, and
  `-RemoveMailboxEmailList` to revoke access to a mailbox again.
- **A re-run no longer re-grants the Entra Graph permissions.** `Mail.ReadWrite`/`Mail.Send` are
  additive to the RBAC scope, and step 5 of the setup removes them on purpose; granting them
  again while adding a mailbox would silently give the app access to every mailbox in the tenant.
  They are now only granted when the run created the app registration itself, or when the new
  `-EnsureEntraGraphPermissions` asks for it explicitly. For the same reason a re-run creates no
  second client secret unless `-NewClientSecret` is given.
- **Further additions to the script:** `-WhatIf` previews a scope change (old filter, new filter,
  added and removed addresses) without writing; `-TestMailbox` takes several addresses and
  defaults to the ones the run just added; the authorization test retries, because Exchange
  Online needs a moment to replicate a scope change and an immediate `InScope: False` is not yet
  a failure; `-RbacScopeName` is a parameter like it already was in `delete-app-registration.ps1`;
  and `-SelfTest` runs the scope-filter assertions offline, without connecting to a tenant.

  The script grants access to mailboxes, it does not create them — the mailboxes still have to
  exist in the tenant.

- **The setup scripts find their resources by a marker, not by name.** Display names were the only
  handle on an installation, so a setup created by hand under a different name than the script's
  default was not found at all — and the script would then build a second, parallel app
  registration and scope instead of extending the first, silently. `setup-azure-app.ps1` now tags
  the app registration (`Tags` contains `RedmineExpertHelpdesk`, configurable via `-ResourceTag`)
  and looks it up by that tag; the service principal is resolved from the AppId; and the management
  scope to extend is read off the app's existing role assignments, so a differently named scope is
  extended rather than duplicated. Installations predating the tag are stamped on the next run, so
  it heals itself. `-AppDisplayName` and `-RbacScopeName` are therefore only needed for the initial
  setup or to disambiguate, and `delete-app-registration.ps1` finds its target the same way. Several
  installations in one tenant are kept apart by `-Environment` (see below).
- **`-Environment` sets up a dev installation alongside the live one.** A dev stack needs its own
  app registration so that its plugin instance cannot reach the live helpdesk mailboxes, and
  keeping the two apart previously meant passing a matching display name and scope name on every
  single run. `-Environment DEV` now derives all three identities at once — tag
  `RedmineExpertHelpdesk:DEV`, app `redmine-expert-helpdesk-dev`, scope
  `Redmine-expert-Helpdesk-Mailboxes-DEV` — so nothing collides and a dev run is just
  `-Environment DEV`. The label is free-form (`TEST`, `STAGING`, …) and case-insensitive;
  `delete-app-registration.ps1` takes it too, so tearing down only the dev side is
  `-Environment DEV`. The default `LIVE` reproduces exactly the names used until now, which is
  locked down by a self-test so existing installations keep being found. Every installation also
  carries the plain `RedmineExpertHelpdesk` tag, which lists all of them in a tenant regardless of
  environment.

### Fixed

- **Images already attached to the ticket never reached the customer.** Only images an agent had
  just pasted or dropped into the form were turned into inline mail parts; anything already stored
  on the ticket was left as `<img src="image001.png">`, a relative path that means nothing in a
  mail client, so the customer received an empty box. This was invisible while the only way to get
  an image into a reply was to paste it, and became obvious the moment quoting made it easy to
  reference the pictures of the original mail. The candidate set now covers the ticket's own image
  attachments as well; a freshly pasted image still wins over an older one of the same name, and
  attachments whose filename does not actually occur in the body are still left out of the mail.
  The resolution moved into `RedmineExpertHelpdesk::ReplyImages`, the outgoing counterpart of
  `InlineImages`, so it is covered by tests instead of living privately in the reply controller.

- **`-WhatIf` did not stop the Entra ID writes.** It was documented as a dry run and guarded the
  Exchange Online calls, but the Microsoft Graph ones ran regardless — so
  `-RemoveEntraGraphPermissions -WhatIf` really removed the permissions, `-NewClientSecret -WhatIf`
  really minted a secret nobody wrote down, and `-EnsureEntraGraphPermissions -WhatIf` really
  re-granted tenant-wide mail access. Every write is now guarded explicitly rather than trusting the
  Graph SDK to honour the preference, and the remaining creates are unreachable under `-WhatIf`
  because the run stops earlier.
- **Values were interpolated into Exchange Online recipient filters without escaping apostrophes.**
  A group DN (`O'Brien`) or an address (`o'brien@example.com`) containing one would have broken the
  scope filter or silently changed which mailboxes it matched. All four scope options escape now,
  reading an address list back understands the escaped form, and escaping is idempotent so a re-run
  cannot add another layer of quotes. The same rule already applied to the Graph `$filter`.
- **`delete-app-registration.ps1` could describe the wrong app in its deletion prompts.** Having
  found an app by tag, it still named the `-AppDisplayName` parameter in the confirmation and used it
  to look up the soft-deleted copy and the Exchange service principal — so for an installation
  carrying a different name, the prompt described one object while another was deleted, and the
  follow-up steps found nothing. It now works from the app it actually found (AppId for the Exchange
  object, real display names elsewhere), and refuses to proceed when several apps share the tag
  unless `-AppDisplayName` or `-Force` says which is meant.
- **The authorization test reported success for a mailbox that was not in scope.** Exchange Online
  returns `InScope` as the string `"False"`, and every non-empty string is truthy in PowerShell, so
  the check inverted itself: it announced "All tested mailboxes are in scope" for a mailbox the app
  could not reach. This gates `-RemoveEntraGraphPermissions`, so acting on it would have removed the
  tenant-wide permissions while the RBAC scope did not actually cover the mailbox — leaving the
  mailbox unreachable. The value is now parsed explicitly and anything unrecognised counts as not in
  scope, and the result set is counted rather than tested for truthiness.
- **The same role was assigned to a scope again on every run.** The check for an existing assignment
  compared `RoleAssigneeName`, a display name that need not equal the app registration's; where it
  differed the check matched nothing and each run added another assignment. Assignments are now
  resolved via `-RoleAssignee`, and duplicates left by earlier runs are reported with the command to
  remove them.
- **Supplying a scope option's parameter without also naming the option was silently ignored.**
  `-MailboxCustomAttributeValue "…"` left `-MailboxScopeOption` at its `EmailList` default, so the
  parameter did nothing and the run aborted asking for `-MailboxEmailList` — a parameter of a
  different option than the one plainly intended. The option is now taken from whichever mailbox
  parameter was supplied; supplying parameters of two options, or one that contradicts an explicit
  `-MailboxScopeOption`, is an error rather than a silent choice. The `EmailList` message also lists
  the other options' parameters now, and the `-TestMailbox` message says which scope it verifies.
- **An apostrophe in `-AppDisplayName` broke the app registration lookup** in both scripts. Single
  quotes delimit strings in an OData filter and have to be doubled to be escaped; unescaped, such a
  name either errored out or silently queried something else — which in `setup-azure-app.ps1` would
  have meant creating a duplicate app registration, and in `delete-app-registration.ps1` not finding
  the app to remove.

### Fixed

- **A failing Microsoft Graph call now says what Graph actually reported.** The message ended at the
  HTTP status, so a 403 could not be told apart from another 403 — `ErrorAccessDenied` (the Exchange
  RBAC scope does not cover this mailbox) and `MailboxNotEnabledForRESTAPI` (the mailbox is inactive,
  soft-deleted or hosted on-premises) look identical that way and need opposite fixes. Graph puts the
  reason in the response body, which the exception already carried but never showed; the code and
  message are now part of it. Unparsable, empty or HTML bodies add nothing rather than raising.

## [0.2.4] - 2026-08-07

### Fixed

- **The AI statistics tab no longer shows up when AI is switched off.** The tab appeared on every
  helpdesk project for anyone holding the global *View AI usage statistics* permission — even with
  both the AI features and the knowledge base disabled, in which case it only ever led to an empty
  page. It is now shown when at least one of the two is enabled (the page reports both AI summary
  and knowledge-base requests, so either one alone makes it meaningful), and the page itself
  answers 403 while both are off instead of being reachable by typing the URL.

- **Duplicate DOM ids on every checkbox in the plugin settings and the mailbox form.** Each
  checkbox is preceded by a hidden field carrying its unchecked value, and Rails derived the same
  id for both from the shared field name — so `getElementById` returned the invisible hidden field
  instead of the checkbox. The hidden companions are id-less now (12 checkboxes across
  *Administration → Plugins → Redmine expert Helpdesk* and the mailbox form). Form submission was
  never affected, which is why this went unnoticed.

### Changed

- **One place decides whether the AI features are on.** The `ai_enabled` / `kb_enabled` check was
  copied into eight controllers, jobs, patches, views and rake tasks, and the AI statistics tab was
  missing it entirely — which is what caused the bug above. All of them now call the new
  `RedmineExpertHelpdesk::AiFeatures` predicates. No behaviour change beyond the fix.

## [0.2.3] - 2026-08-06

### Added

- **Tickets awaiting a response are now visible at a glance.** When a customer replied by mail —
  or a reply reopened a closed ticket — nothing marked the ticket as needing attention, so agents
  had to fall back on filtering by SLA status. A ticket is now flagged **Awaiting response** the
  moment an inbound reply arrives on an existing ticket, and the flag clears as soon as an agent
  posts a public note or closes the ticket. Four surfaces show it: a sortable **Awaiting response**
  column plus filter in the ticket list, a highlighted row, a counter in the ticket-list sidebar,
  and a *Helpdesk: awaiting response* block for My Page. Private notes deliberately do not clear
  the flag — an internal remark is not an answer to the customer. Turn the whole thing off under
  *Administration → Plugins → Redmine expert Helpdesk*.

- **Short mails no longer cost an AI call.** A two-line "please call me back" summarizes to
  itself, yet every ingested mail went to the provider. The new central setting **Min. input
  characters** (*Administration → Plugins → Redmine expert Helpdesk*, default 200) sets the
  threshold: below it, `HelpdeskAiSummaryJob` skips the provider (and the knowledge-base
  retrieval) and posts a private note stating that the summary was skipped and why. The note
  is recorded like any other AI note, so it keeps its 🤖 journal badge (0 tokens) and the
  saved call shows up in the usage statistics. Whitespace is normalized before measuring, so quoted-printable
  line noise does not inflate the length; mails with images always go to the AI, and `0`
  disables the check.
- **AI diagnostics have their own log level.** The new `RedmineExpertHelpdesk::AiLogger`
  (counterpart of `MailLogger`) writes the measured input length and the skip decision as
  `[helpdesk][ai] length issue=#… chars=… min=… images=… decision=skip|summarize`, at the
  severity set by **Log level for AI diagnostics** (*Logging*, default `debug`, `off` to
  silence). Rails runs its logger at `:info` in production, which would swallow a `debug` line
  and make the setting look broken, so a line below the logger's threshold is raised to that
  threshold and carries its own severity in the prefix instead. Without the line the threshold
  could only be tuned by guessing what a given mail measured.

### Fixed

- **Auto-reopening a ticket now shows up in its history.** `MailProcessor` set the reopen status
  with `save(validate: false)` and without a journal, so the status jumped from closed to open with
  no trace in the ticket history or the activity feed. The status change is now recorded as a
  detail on the journal the inbound reply already creates — one history entry instead of two, and
  no additional notification mail.

- **Graph was offered as the send path for IMAP mailboxes it cannot serve.** Sending an IMAP
  mailbox's mail through the central Graph registration is legitimate for "Microsoft 365 over IMAP"
  (and the only working path in tenants that disable SMTP AUTH), but the rule that decided it read
  the mailbox's own `oauth_preset` **column** — which is not in effect when credentials come from the
  plugin settings, the default. A mailbox on global credentials was therefore judged by a value
  nobody was using: blank (the REST API never backfills it) refused Graph for a genuine Microsoft
  mailbox, a stale `microsoft` allowed it on an install whose global template is Google. On top of
  that, nothing checked whether a central app registration existed at all, so on a pure IMAP install
  `graph` could be selected and saved and then failed at send time. `HelpdeskMailbox#microsoft_hosted?`
  now asks `MailboxCredentials.preset_for` for the **effective** preset, and the new
  `#graph_transport_available?` additionally requires configured central credentials (a Graph mailbox
  stays exempt — its own backend is Graph either way, and requiring credentials there would make it
  unsavable while the Azure app is still being set up). The mailbox form applies the same rule, so
  the option no longer appears where it cannot work.

### Changed

- **The send path moved next to the mail provider in the mailbox form.** "Send via" sat in the
  *Reply templates* section, between header, footer and signature preview — a transport choice
  filed under text snippets, and one that governs replies, initial mails and the autoresponder
  alike, not just replies. It now sits directly under *Provider* at the top of the form, where
  "how mail comes in" and "how mail goes out" are read together. No stored value or field name
  changed (`reply_transport`), so nothing needs re-configuring.

### Added

- **Every outgoing mail is logged with the transport it took.** Outgoing mail leaves the plugin
  through three transports (Graph `sendMail`, the mailbox's own SMTP server, Redmine's global
  ActionMailer SMTP) from four places (agent reply, initial mail, autoresponder, SLA breach
  notification) — when a customer reported a missing mail, nothing in the log said *which way* it
  had been sent. All send sites now funnel through `RedmineExpertHelpdesk::MailLogger`, which
  writes one line per mail containing the route (including SMTP host/port), mailbox, project,
  issue, recipients, message id and subject. Failed sends are logged at **error** level with the
  exception and re-raised, so existing error handling is unchanged. The severity of the success
  line is configurable under *Administration → Plugins → Redmine expert Helpdesk → Logging*
  (`mail_log_level`, default `info`; `debug` keeps it out of a production log).

## [0.2.2] - 2026-08-04

### Added

- **Mailboxes in the REST API.** The mail backend gained a large configuration surface with the
  generic IMAP/SMTP support (provider choice, IMAP/SMTP hosts, OAuth2 grants and presets, sent
  folder), but none of it was reachable from the API — mailboxes were UI-only, and the embedded
  mailbox reference on a ticket did not even say which backend the mail had arrived through.
  There is now a full CRUD resource: `GET`/`POST /projects/:id/helpdesk/mailboxes` and
  `GET`/`PUT`/`DELETE /helpdesk/mailboxes/:id`, plus
  `POST /helpdesk/mailboxes/:id/test_connection` to probe the stored configuration and list its
  folders. Reading requires `manage_helpdesk` just like writing, because the configuration
  exposes hosts, usernames and OAuth client/tenant ids. **Secrets are write-only**:
  `mail_password`, `oauth_client_secret` and `oauth_sa_key` can be set but are never returned —
  responses carry `mail_password_set`-style booleans instead — and sending `"-"` clears a stored
  secret, matching the UI's masked-field behaviour. The interactive OAuth consent stays in the
  UI; `oauth_connected` tells an API client when it is still outstanding. The embedded mailbox
  reference on tickets and messages now carries `provider`. See `API.md`.
- **AI and knowledge-base settings in the project settings API.** `GET`/`PUT
  /projects/:id/helpdesk/settings` silently omitted every `ai_*` and `kb_*` field, so the AI
  summary and RAG knowledge base could only be configured through the UI. Both are now read and
  written like the SLA and phishing settings.
- **`docs/redmine_org/` — maintained copy-paste sources for the redmine.org plugin directory.**
  The listing at <https://www.redmine.org/plugins/redmine_expert_helpdesk> renders Textile, not
  Markdown, so the description had to be hand-converted on every update and had silently gone
  stale: it still advertised "only Microsoft O365 is supported" after 0.2.0 shipped the generic
  IMAP/SMTP backend. `description.textile`, `installation.textile` (the directory keeps those in separate
  fields) and `releases/<version>.textile` now hold the current text, ready to paste unedited. Keeping them
  current is part of cutting a release (documented in `CLAUDE.md` and
  `.github/copilot-instructions.md`); `docs/` is excluded from the release archives, so none of it
  ships to users.

### Fixed

- **Both READMEs had no table of contents.** They run past 1150 lines with around 20 top-level
  sections, so finding out whether the plugin documents, say, the knowledge base or the release
  process meant scrolling the whole file. Each now opens with a contents list in document order,
  the three mail-provider recipes nested under *Mail providers*.
- **`README.de.md` had drifted from the English structure**, which the language policy asks us to
  keep in sync. The AI-summary and knowledge-base sections sat near the end instead of after the
  REST API; the CI description was a subsection of *Tests ausführen* where English gives it its
  own *Tests* section; and *Assigning a contact to an existing ticket* was missing from the German
  file altogether. Section order and subsection counts now match one-for-one.
- **The redmine.org sources did not mention the REST API.** `description.textile` listed every
  other feature but left the API to a bare link at the bottom, and `installation.textile`
  documented only the two key-secured cron endpoints — so nothing told a reader that the REST
  web service has to be enabled in *Administration → Settings → API*, or that mailbox endpoints
  need `manage_helpdesk` to read. Both now cover it.
- **The README still introduced the plugin as Microsoft-365-only.** Its opening sentence —
  "Email-to-ticket plugin for Redmine with Microsoft 365 integration via the Microsoft Graph API"
  — predated the generic IMAP/SMTP backend, so the one paragraph most readers see contradicted
  the feature list right below it. This is the same silent drift that had left
  `docs/redmine_org/description.textile` advertising "only Microsoft O365 is supported" after
  0.2.0 shipped. Also corrected the *Customer replies* bullet, which described the Graph
  `sendMail` path as the only way a reply leaves the system, and noted in *Prerequisites* that
  `rake db:create RAILS_ENV=test` cannot work alongside the RedmineUP plugins (it boots Rails,
  and `redmine_contacts` calls `table_exists?` against the database that does not exist yet).
- **Phishing detection crashed on Ruby 4.0 (Redmine 7 images).** `PhishingScanner` used `CGI.parse`
  to pull the wrapped target out of Microsoft SafeLinks and other redirect links, and Ruby 4.0
  removed that method — every link with a query string raised `NoMethodError: undefined method
  'parse' for class CGI`, so SafeLinks were no longer decoded and redirect links were never
  flagged. Query strings are now parsed with `URI.decode_www_form_component` behind a small
  `query_pairs` helper. Deliberately not `URI.decode_www_form`: it raises on a segment without
  `=` and then discards the whole query string along with the valid pairs, whereas `CGI.parse`
  was tolerant — and the redirect links this code exists to unwrap are rarely well-formed.

## [0.2.1] - 2026-08-04

### Changed

- **The folder fields on the mailbox form are real comboboxes now.** All five (source, processed,
  skipped, failed, sent) were `<input list="…">` bound to a shared `<datalist>`. Browsers draw that
  popup exactly like their own autofill history — no dropdown affordance, no way to style it, and
  prefix-only matching in several of them — so a folder actually read from the mailbox was
  indistinguishable from a value typed there once before. Each field now has a `▾` toggle that
  opens the full list, filters by substring as you type (so `arbeit` finds `Verarbeitet`), and
  supports arrow keys, Enter, Escape and mouse selection. Free text is still valid: a folder that
  does not exist yet is offered as `+ "…" anlegen` and is still created on submit, so the existing
  create-on-save flow is untouched. Vanilla JS, no new dependency
  (`assets/stylesheets/helpdesk_mailbox_form.css`).

## [0.2.0] - 2026-08-04

### Added

- **GitHub issue templates.** Bug reports and feature requests are now filed through YAML issue
  forms in `.github/ISSUE_TEMPLATE/`, so the details that were previously missing from most
  reports — plugin version, the Administration → Information table, and the affected area — are
  required up front. Free-form issues are disabled; `config.yml` points at the README and `API.md`
  instead.
- **Generic IMAP/SMTP mailboxes with modern authentication.** Until now the plugin could only
  ingest mail from Microsoft 365 via the Graph API — Google Workspace, Exchange on-premises,
  self-hosted Dovecot/Zimbra and ordinary hosters were out of reach. A mailbox now selects its
  backend with the new `provider` column (`graph` — unchanged default — or `imap`). Incoming mail
  arrives over IMAP (`lib/redmine_expert_helpdesk/imap_client.rb`), outgoing mail leaves over the
  mailbox's own SMTP server (`smtp_sender.rb`), and both are wrapped by `imap_provider.rb`.
  Migrations `034` and `035`.
- **OAuth2 (XOAUTH2) as the default authentication, with three grants.** `client_credentials`
  (app-only; Microsoft IMAP needs `IMAP.AccessAsApp` / `SMTP.SendAsApp` granted in the tenant),
  `authorization_code` (one interactive consent, refresh token stored encrypted — for Gmail and
  arbitrary identity providers) and `jwt_bearer` (Google service account with domain-wide
  delegation, the assertion signed with `OpenSSL::PKey::RSA` so no `jwt`/`googleauth` gem is
  needed). Implemented in `oauth_token_provider.rb`; the shared SASL string lives in `xoauth2.rb`.
  Username/password over TLS remains available as a secondary `auth_method` for servers without
  OAuth2. **No new gems** — `net/imap` and `net/smtp` already ship as runtime dependencies of the
  `mail` gem Redmine bundles.
- **OAuth consent flow.** New `HelpdeskOauthController` with a *single fixed* callback URL
  (`/helpdesk/oauth/callback`), because identity providers only accept exactly registered redirect
  URIs; the mailbox id travels in a signed, ten-minute `state`
  (`Rails.application.message_verifier`) rather than in the path. The mailbox form shows the URL
  read-only next to a Connect/Reconnect button and the connection date.
- **Connection presets** for Microsoft 365, Google Workspace and generic servers
  (`provider_presets.rb`) prefill hosts, ports, endpoints and scopes. They are applied both in the
  form and server-side in `HelpdeskMailbox#apply_preset!`, so API-created mailboxes get them too,
  and they **never overwrite a value that was entered manually**.
- **"Test connection" button** in the mailbox form (`HelpdeskMailboxesController#test_connection`)
  reports the authentication result and lists the folders it can see, for both providers.
- **Encrypted secrets at rest.** Per-mailbox passwords, client secrets, refresh tokens and service
  account keys are stored through `secret_box.rb` (`ActiveSupport::MessageEncryptor` keyed off
  `secret_key_base` — `ActiveRecord::Encryption` is Rails 7+ and this plugin still supports
  Redmine 5.1). Values carry an `enc:v1:` prefix; anything without it is returned unchanged, so
  legacy plaintext stays readable and no data migration is forced. Note that rotating
  `secret_key_base` makes stored secrets unrecoverable — they then have to be re-entered.
- **A copy of outgoing mail is filed in the mailbox's Sent folder.** Graph's `sendMail` does this
  by itself; plain SMTP does not, so an IMAP helpdesk mailbox showed the inbound half of every
  conversation and nothing else. `ImapClient#append_sent` now files the message as read, whichever
  route sent it — including Redmine's global relay, which files nothing anywhere. The folder is
  taken from the server's own RFC 6154 `\Sent` flag, then the new `sent_folder` column, then the
  preset (`Sent Items` / `[Gmail]/Sent Mail` / `Sent`); "Test connection" reports which one it
  resolved. **A failed APPEND is logged and swallowed** — by that point the customer already has
  the mail, and an archiving problem must never look like a send failure.

### Changed

- **`MailProcessor` is now provider-neutral.** It talks to a `MailProvider` instead of `GraphClient`
  and consumes a normalized `MailProvider::MessageMeta` struct instead of reading raw Graph JSON
  keys (`meta['subject']`, `meta.dig('from','emailAddress','address')`, …). A whole fetch cycle runs
  inside one `provider.with_session` block, so IMAP opens a single connection per fetch rather than
  one per message. `GraphProvider` adapts the **unchanged** `GraphClient`; `GraphClient::GraphError`
  now inherits from `MailProvider::ProviderError`, which widens the existing rescues in
  `HelpdeskFetchController` and `HelpdeskRepliesController` without further churn.
- **Reply transport gained a `provider` option** (`REPLY_TRANSPORTS`), the new default for new
  mailboxes: replies go out over whatever the mailbox itself is configured for — Graph, or its own
  SMTP server. The legacy `graph` and `smtp` (Redmine's global ActionMailer settings) values behave
  exactly as before. Wired through `HelpdeskRepliesController` and `InitMailer#send_provider_mime`.
- **Credential precedence is now explicit.** `credentials_source` (`global` | `mailbox`) decides
  where a mailbox reads its credentials from; blank fields are deliberately **not** backfilled from
  the other source, because a half-filled mailbox silently authenticating against the wrong tenant
  is the failure mode that makes two sources of truth unsupportable. `graph` + `global` is
  byte-identical to the previous behaviour. Global defaults for IMAP/SMTP mailboxes were added to
  the plugin settings partial and `init.rb`.
- **The Graph access-token cache key now includes a credential fingerprint.** Rotating the client
  secret used to leave a stale token in the cache for up to an hour.

### Fixed

- **Rotating an OAuth2 client secret did not invalidate the cached access token.** The comment on
  `OauthTokenProvider#cache_key` promised that "changing any credential changes the key", but the
  fingerprint covered only `client_id`, `tenant_id`, `token_url`, `scope` and the grant — none of
  which move when just the secret is rotated. The token issued for the superseded secret therefore
  stayed in use until it expired (up to `expires_in - 120` seconds). The secrets are now part of
  the fingerprint, which is a SHA-256 digest, so nothing sensitive reaches the cache key itself.
  The existing test for this could never have caught it: Redmine's test environment uses a null
  cache store, so the "cached" token was silently discarded and every lookup looked like a fresh
  request.
- **Presets and global connection defaults could never set a port or an encryption mode.**
  `HelpdeskMailbox#apply_preset!` assigns only where `self[attr].blank?`, but migration `034` gave
  `imap_port` / `imap_security` / `smtp_port` / `smtp_security` column defaults (993 / `ssl` /
  587 / `starttls`), and a column default is never blank — so the assignment was skipped every
  time. Only `imap_host` and `smtp_host`, which have no column default, ever worked. The
  precedence rule documented in `apply_preset!` (a named preset outranks the global defaults, the
  `generic` preset yields to them) was therefore dead code for four of its six attributes. It went
  unnoticed because the `microsoft` and `google` presets use 993/587 themselves. Migration `037`
  drops the four defaults and hands the decision back to `apply_preset!`; `ImapClient#port` and
  `SmtpSender#port` already fall back per security mode on an empty column. Stored values are
  untouched.
- **A new IMAP mailbox defaulted to a reply transport its own validation rejects.**
  `reply_transport` defaulted to `graph` (migration `014`, back when Graph was the only backend),
  while `#available_reply_transports` offers `graph` only to `microsoft_hosted?` mailboxes — so a
  plain IMAP mailbox had to have the value overwritten by the form before it could save. Migration
  `037` changes the default to `provider` ("this mailbox's own backend"), which is valid for every
  mailbox; for a Graph mailbox `#outgoing_route` resolves it straight back to `graph`.
- **The autoresponder ignored the mailbox's reply transport.** `MailProcessor#send_autoresponder`
  called `GraphClient#send_mail_mime` unconditionally, so a mailbox configured for SMTP still sent
  its automatic acknowledgements through the Graph API — and an IMAP mailbox could not have sent
  them at all. It now uses the mailbox's provider like every other outgoing path.
- **Hardening: the folder AJAX endpoints trusted an arbitrary `mailbox_address` parameter.**
  `HelpdeskMailboxesController#folders` / `#create_folder` / `#ensure_mailbox_folders` built a
  `GraphClient` straight from that parameter, so anyone with `manage_helpdesk` on any project could
  enumerate or create folders in **any** mailbox the central Azure app registration could reach.
  They now build the provider from the submitted form state scoped to the current project, or from
  the persisted record — whose secrets never travel back to the browser.
- **Boot failure and a dead OAuth controller, both caused by autoloading.** `oauth_token_provider.rb`
  defined `OAuthTokenProvider`, while Zeitwerk's default inflector expects `OauthTokenProvider` from
  that filename — Redmine aborted at startup with a `Zeitwerk::NameError`. Separately, the new
  controller was named `HelpdeskOauthController`, the same name RedmineUP's
  `redmine_contacts_helpdesk` already ships; since all plugins share one autoload path, only their
  class was ever loaded and the mailbox form died with `undefined method 'callback_url'`. Ours is
  now `ExpertHelpdeskOauthController` with `expert_helpdesk_oauth_*` route helpers. The public
  callback path `/helpdesk/oauth/callback` is unchanged, so nothing has to be re-registered with an
  identity provider.

- **Redundant and dead global settings.** The plugin settings offered *two* application
  registrations — the long-standing `tenant_id`/`client_id`/`client_secret` and a second
  `default_oauth_tenant_id`/`_client_id`/`_client_secret` triple — for what is, in the Microsoft
  case, the same Entra app, with a precedence rule nothing on screen explained. The second triple
  is gone; there is now exactly one central registration, shared by Graph and OAuth2 IMAP/SMTP.
  Conversely `default_imap_host`/`_port`/`_security` and `default_smtp_host`/`_port`/`_security`
  were stored but read by nothing at all — they now serve as the fallback the "Other / self-hosted"
  preset uses, so an operator with one mail server can configure it once instead of on every
  mailbox. A named preset (Microsoft, Google) still wins, and an explicit value on the mailbox
  wins over both.
- **"Netzwerkfehler" instead of a folder list on every saved mailbox.** The hardened folder
  endpoint sends the whole form via `new FormData(form)`, which on an edit page also picks up
  Rails' hidden `_method=put` field. Rails honoured it, turned the POST into a PUT against the
  member route and ran `#update` with `id="folders"` — a 404 whose HTML body then broke the
  JSON parser, so the form reported a network error. The field is now stripped from the payload,
  and a non-JSON response reports its actual HTTP status instead of a blanket "Netzwerkfehler".
  Affected "Ordner laden", "Ordner anlegen" and "Verbindung testen" on existing mailboxes; new
  mailboxes were fine, since their form carries no `_method`.

- **Password login for simple IMAP/SMTP servers now negotiates its mechanism.** Both protocols
  pinned exactly one: IMAP always sent the `LOGIN` command, SMTP always asked for `AUTH LOGIN`.
  A server that advertises `LOGINDISABLED` (RFC 3501 requires it on unprotected connections, and
  Dovecot sets it) or that offers only `PLAIN` or `CRAM-MD5` therefore rejected perfectly correct
  credentials with what looked like an authentication failure. `ImapClient` now falls back to
  `AUTHENTICATE PLAIN`/`LOGIN` when the plain command is refused, and `SmtpSender` picks the first
  of `PLAIN`, `LOGIN`, `CRAM-MD5` the server actually advertises. If none is usable the error says
  so and points at the encryption setting, instead of claiming bad credentials.
- **The IMAP capability list is re-read after logging in.** It was cached from the pre-auth
  response, and `MOVE` and `UIDPLUS` are commonly advertised only once authenticated — so the
  client could take the destructive plain-`EXPUNGE` path against a server that supports neither.

- **The autoresponder ignored the `smtp` reply transport too.** The previous fix moved it off its
  hard-coded Graph call onto the mailbox's provider, which is right for the `provider` and `graph`
  transports but still bypassed *SMTP (Redmine default)* — a mailbox set to send through Redmine's
  own ActionMailer configuration had its automatic acknowledgements go out through the Graph API
  or its own SMTP server instead. `MailProcessor#deliver_autoresponder` now follows the same
  three-way rule as replies and initial mails, and `graph` correctly means the central
  registration even when the mail arrived over IMAP.

- **An IMAP mailbox could be configured to send through Microsoft Graph.** The transport select
  offered all three values to every mailbox, so a Gmail or Dovecot mailbox could be pointed at
  `POST /users/{address}/sendMail` against the central Azure registration — a 404 discovered at
  send time, with the customer's reply lost. `graph` is now offered and accepted only for a
  mailbox Microsoft actually hosts: a `graph` mailbox, or an `imap` mailbox on the Microsoft
  preset (the legitimate "Microsoft 365 over IMAP" setup). The form hides the option and
  `HelpdeskMailbox` validates the same rule, so the API cannot store it either.
- **Every outgoing path decided for itself which provider sends.** The replies controller,
  `InitMailer` and `MailProcessor` each carried their own copy of that branch, and each was wrong
  at least once — most recently the autoresponder. There is now one
  `MailProvider.outgoing_for(mailbox)`, and `effective_reply_transport` is renamed to
  `outgoing_route`, since it governs replies, initial mails and the autoresponder alike rather
  than replies only.

### Changed (configuration UI)

- **The settings page now shows only the fields the selected provider type actually needs.** The
  preset select comes first and governs the rest: the tenant ID appears for Microsoft only, the
  authorize/token URLs, scope and IMAP/SMTP hosts for "Other / self-hosted" only, the callback URL
  only for the one-time-consent flow, and the Azure hints only for Microsoft. The API keys for the
  cron endpoints moved into their own section, since they have nothing to do with mail credentials.
- **The mailbox form hides its own credential fields when the mailbox is set to use the plugin
  settings.** Those fields are ignored entirely in that mode, and leaving them on screen displayed
  a second set of values that had no effect. The same preset-driven rules as above apply to the
  tenant ID and the URL/scope trio. The "Connect" button stays visible either way — the refresh
  token belongs to the mailbox, not to the application registration.

- **"Test connection" probes the route the mailbox actually sends over** instead of always
  probing SMTP: SMTP for its own server, Graph for the Graph route, and nothing for the Redmine
  relay, whose health is Redmine's own business.

### Migration

- `036_add_sent_folder_to_helpdesk_mailboxes.rb` — `sent_folder`. Blank means "ask the server",
  so no configuration is required.
- `034_add_provider_to_helpdesk_mailboxes.rb` — `provider`, `credentials_source`, `imap_host`,
  `imap_port`, `imap_security`, `imap_username`, `imap_verify_ssl`, `imap_unseen_only`,
  `imap_timeout`, `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username`, `smtp_verify_ssl`,
  `auth_method`, `mail_password_enc`.
- `035_add_oauth_tokens_to_helpdesk_mailboxes.rb` — `oauth_preset`, `oauth_grant`,
  `oauth_tenant_id`, `oauth_client_id`, `oauth_client_secret_enc`, `oauth_authorize_url`,
  `oauth_token_url`, `oauth_scope`, `oauth_refresh_token_enc`, `oauth_token_expires_at`,
  `oauth_connected_at`, `oauth_sa_email`, `oauth_sa_key_enc`.
- Both are idempotent (`unless column_exists?`). Existing mailboxes default to `provider = 'graph'`
  and `credentials_source = 'global'`, so **no configuration change is required** for current
  installations.

### Notes on IMAP behaviour

- UIDs are used throughout (`UID SEARCH`/`FETCH`/`STORE`/`MOVE`); sequence numbers shift under
  concurrent mailbox activity.
- Fetches use `BODY.PEEK[...]`, never `BODY[...]`, which would silently set `\Seen`.
- Folder names are stored as human-readable UTF-8 with `/` and translated to modified UTF-7 plus
  the server's own hierarchy delimiter on the wire — German folder names such as
  `Gelöschte Elemente` depend on this.
- Moving uses `MOVE` (RFC 6851) when advertised, otherwise `COPY` + `\Deleted` + `UID EXPUNGE`
  (UIDPLUS). Servers offering neither fall back to a plain `EXPUNGE`, which also removes **other**
  messages already flagged `\Deleted` in the source folder; this is logged as a warning and stated
  in the UI.

## [Unreleased] 2026-07-24 (85)

### Added
- **Documentation: "Flow per mailbox fetch" brought back in sync with `MailProcessor`.** The
  diagram had drifted and was missing the auto-reply filter, the phishing scan
  (quarantine vs. neutralize), the MIME preprocessing stage (thread-header stripping for the
  reopen-age limit, `Auto-Submitted` stripping on NDRs, `In-Reply-To`/`References` injection),
  ticket reopening on replies, the `HelpdeskTicketInfo` link and the async AI-summary enqueue. It
  also showed a single "target folder" where the code actually uses three
  (`processed_folder` / `skipped_folder` / `failed_folder`, with fallbacks). Adds notes on target
  folders and per-message failure isolation. Mirrored in `README.de.md`.
- **`LICENSE` file (GPL-2.0-or-later)** — the plugin is now explicitly licensed under the GNU
  General Public License v2 or later, matching Redmine itself. Adds a copyright/license header to
  `init.rb` and a **License** plus **Third-party components** section to `README.md` /
  `README.de.md` (documenting the bundled MIT-licensed Chart.js 4.4.6 and
  chartjs-plugin-datalabels 2.2.0, both served locally — no CDN request at runtime).
- **AI usage statistics** dashboard: a per-project **"AI statistics"** tab (mirroring the SLA
  dashboard — time-frame selector, at-a-glance totals, Chart.js visualisations) covering request
  volume, token usage, request-type/provider-model breakdown, success/failure, latency and busiest
  times. Backed by a new unified **AI request log** (`helpdesk_ai_requests`, migration 033) that
  records **every** AI call — summaries, KB extraction, embeddings and RAG retrieval — including
  failures (previously only logged) and embedding-token usage (previously discarded). Access is
  gated by a new **global** permission `view_helpdesk_ai_statistics` (grant it to a role, e.g.
  "ai-admin", to see the tab on all helpdesk projects). Tokens only — no cost/pricing yet.
- **Administration menu** entry ("expert Helpdesk", with a headset icon) that links directly to
  the plugin settings, so the configuration is reachable in one click from the Administration
  sidebar and the Administration index — instead of going via *Plugins → Configure*. The icon is
  version-aware: a plugin SVG-sprite icon on Redmine 6/7, the legacy `icon-*` CSS icon on Redmine 5
  (`init.rb`, `assets/images/icons.svg`).

### Fixed
- Issue list view: the JavaScript-injected **"Neues Helpdesk-Ticket"** button (next to "Neues Ticket")
  was rendered mangled under Redmine 7 — it still used the old `icon icon-*` CSS class, which Redmine 7
  removed, so no icon was supplied. Like the other JS-generated buttons, it now prepends the SVG sprite
  icon via `window.hdSpriteIcon('email')` (falling back to a plain label when unavailable)
  (`lib/redmine_expert_helpdesk/hooks.rb`).

### Changed
- **Documentation examples now use neutral placeholders**: the Microsoft Graph / Exchange setup
  snippets in `README.md`, `README.de.md` and `scripts/setup-azure-app.ps1` use
  `helpdesk.example.com` / `@example.com` throughout, and the development-workflow section of
  `CLAUDE.md` refers to the repository root relatively instead of by absolute path. This makes the
  examples copy-pasteable for any installation — `-MailboxDomainSuffix` / `-MailboxEmailList` are
  per-installation parameters and always had to be supplied. No functional change.
- **Screenshots in both READMEs**: `README.md` and `README.de.md` now open with a short gallery of
  the main screens (SLA statistics, AI statistics, customer list, ticket view) and carry inline
  screenshots in the customer, AI-summary and knowledge-base sections, so the plugin can be
  evaluated without installing it first. Images live in `docs/screenshots/{en,de}/` and are
  **excluded from the release archives** (`--exclude='docs'` in `.github/workflows/release.yml`),
  so the installable package does not grow.
- **New maintenance scripts** `scripts/seed_screenshot_demo.rb` and
  `scripts/teardown_screenshot_demo.rb` build and remove the synthetic demo project the
  screenshots are taken from (contacts, tickets with a realistic SLA mix, AI request log,
  knowledge-base entries). Both are scoped to a single project, write no global settings and are
  excluded from the release archives along with the rest of `scripts/`.
