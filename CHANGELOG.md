# Changelog – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> This English changelog starts fresh on 2026-07-24. Entries predating it live only in the German
> `CHANGELOG.de.md`. From here on, every change is recorded in **both** files (EN authoritative —
> GitHub release notes are generated from this file).

## [Unreleased] 2026-07-30 (86)

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
- **`docs/redmine_org/` — maintained copy-paste sources for the redmine.org plugin directory.**
  The listing at <https://www.redmine.org/plugins/redmine_expert_helpdesk> renders Textile, not
  Markdown, so the description had to be hand-converted on every update and had silently gone
  stale: it still advertised "only Microsoft O365 is supported" after 0.2.0 shipped the generic
  IMAP/SMTP backend. `description.textile`, `installation.textile` (the directory keeps those in separate
  fields) and `releases/<version>.textile` now hold the current text, ready to paste unedited. Keeping them
  current is part of cutting a release (documented in `CLAUDE.md` and
  `.github/copilot-instructions.md`); `docs/` is excluded from the release archives, so none of it
  ships to users.

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

### Fixed
- **Phishing detection crashed on Ruby 4.0 (Redmine 7 images).** `PhishingScanner` used `CGI.parse`
  to pull the wrapped target out of Microsoft SafeLinks and other redirect links, and Ruby 4.0
  removed that method — every link with a query string raised `NoMethodError: undefined method
  'parse' for class CGI`, so SafeLinks were no longer decoded and redirect links were never
  flagged. Query strings are now parsed with `URI.decode_www_form_component` behind a small
  `query_pairs` helper. Deliberately not `URI.decode_www_form`: it raises on a segment without
  `=` and then discards the whole query string along with the valid pairs, whereas `CGI.parse`
  was tolerant — and the redirect links this code exists to unwrap are rarely well-formed.
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
