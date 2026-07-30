# Changelog – redmine_expert_helpdesk

> 🇬🇧 English version · [Deutsche Version](CHANGELOG.de.md)
>
> This English changelog starts fresh on 2026-07-24. Entries predating it live only in the German
> `CHANGELOG.de.md`. From here on, every change is recorded in **both** files (EN authoritative —
> GitHub release notes are generated from this file).

## [Unreleased] 2026-07-30 (86)

### Added
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

### Migration
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
