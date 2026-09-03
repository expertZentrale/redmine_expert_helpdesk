> English version · [Deutsche Version](README.de.md)

# Redmine expert Helpdesk

[![CI](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/ci.yml)
[![Docker image smoke test](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml/badge.svg)](https://github.com/expertZentrale/redmine_expert_helpdesk/actions/workflows/docker-image.yml)

Email-to-ticket plugin for Redmine. Each mailbox picks its own backend: **Microsoft 365**
via the Microsoft Graph API, or generic **IMAP/SMTP** for Google Workspace, Exchange
on-premises, self-hosted servers and any hoster — authenticating with OAuth2/XOAUTH2 or,
where the server has no OAuth2, username and password over TLS.

Two CI workflows run on every push and pull request: the
[test suite](.github/workflows/ci.yml) (MiniTest against Redmine source for all
supported versions — 5.1, 6.0, 6.1, 7.0 — on a clean MariaDB) and a
[Docker image smoke test](.github/workflows/docker-image.yml) that boots the plugin
inside the **official `redmine` Docker images** we deploy with (tags 5.1, 6.0, 6.1, 7.0) —
see [Tests](#tests).

## Contents

- [Features](#features)
- [Screenshots](#screenshots)
- [Mail providers](#mail-providers) — backends, credentials, authentication
  - [Recipe: Microsoft 365 over IMAP (application only)](#recipe-microsoft-365-over-imap-application-only)
  - [Recipe: Google Workspace / Gmail (one-time consent)](#recipe-google-workspace--gmail-one-time-consent)
  - [Recipe: self-hosted server (Dovecot, Zimbra, hoster)](#recipe-self-hosted-server-dovecot-zimbra-hoster)
- [Email Processing](#email-processing) — fetch flow, reply matching, sending replies
- [Contacts / Customer List](#contacts--customer-list)
- [Quoting prior content](#quoting-prior-content)
- [Answer templates](#answer-templates)
- [Triggering a Mail Fetch](#triggering-a-mail-fetch)
- [Triggering the SLA Check](#triggering-the-sla-check)
- [Plugin Settings](#plugin-settings)
- [REST API](#rest-api)
- [AI summaries](#ai-summaries)
- [Completeness check for incoming mail](#completeness-check-for-incoming-mail)
- [Knowledge base (RAG)](#knowledge-base-rag)
- [Tests](#tests) — what CI runs
- [Azure App Registration (one-time setup)](#azure-app-registration-one-time-setup)
- [Installation](#installation)
- [Template Macros](#template-macros)
- [Notes](#notes)
- [Running the Tests](#running-the-tests) — running them yourself
- [License](#license)
- [Third-party components](#third-party-components)

## Features

- **Email to ticket**: Mails from Microsoft 365 or any IMAP mailbox are created as tickets;
  replies are matched to existing tickets via `In-Reply-To` / `[#id]` subject
  patterns (uses Redmine's standard `MailHandler`, including attachments).
- **Embedded images in the ticket**: The inline images of a mail (signature logos,
  screenshots) are shown where the mail showed them instead of leaving a
  `[cid:…]` marker behind — see [Embedded images](#embedded-images).
- **Per-project mailboxes**: Each project configures its mailboxes under the
  *Helpdesk* tab in project settings (source/target folder, defaults for
  tracker/priority/status, handling of unknown senders).
- **Any mail provider**: Each mailbox chooses its backend — Microsoft 365 via the
  Graph API, or generic **IMAP/SMTP** for Google Workspace, Exchange on-premises,
  self-hosted servers (Dovecot, Zimbra) and any hoster. Authentication is
  **OAuth2/XOAUTH2** by default (application-only, one-time consent, or a service
  account), with username/password over TLS available for servers without OAuth2.
  See [Mail providers](#mail-providers).
- **Central app registration**: Tenant ID, Client ID and Client Secret are
  configured once under *Administration → Plugins → Redmine expert Helpdesk*;
  individual mailboxes may override them with their own credentials.
- **Autoresponder**: Configurable confirmation email for new tickets.
- **Completeness check**: Optionally evaluates the first mail of a new ticket — rule-based
  or AI-powered — and asks the customer automatically for the details that are missing.
- **Customer replies**: Reply to the customer directly from the ticket page,
  with header/footer templates; sent as full MIME from the project mailbox over
  whichever backend it uses — Graph or its own SMTP server — and filed in its
  "Sent Items" either way. Supports inline images (CID method), regular
  attachments and multiple recipients in CC/BCC.
- **Quoting and answer templates**: A **Quote** button next to the formatting
  icons of the note field inserts the original email, the complete conversation
  or only the mail exchange — private notes never among them. A **Templates**
  button inserts a canned response, macros already resolved. See
  [Quoting prior content](#quoting-prior-content) and
  [Answer templates](#answer-templates).
- **Address field autocomplete**: Typing in To/CC/BCC fields suggests matching
  project contacts (from 2 characters, dropdown with keyboard and mouse
  navigation, comma-separated multi-value). Display names containing commas
  are automatically quoted per RFC 2822.
- **Contacts**: Senders are automatically saved as contacts; customer list in
  the project (paginated, configurable entries per page), customer info panel
  with previous tickets on the ticket page. The issue list offers sortable
  **"Customer" and "Customer email" columns** plus a customer filter matching
  name or email.
- **Black-/whitelist**: Sender and domain filters per mailbox.
- **SLA**: Per-project reaction and solution time targets in business minutes
  (working days + time range configurable per project), optional per-priority
  overrides. Traffic-light display on the ticket, tracking of first response
  and resolution time, optional breach notification to an escalation email
  and/or project user (triggered via a dedicated `helpdesk/sla_check` cron
  endpoint, secured by its own API key). The issue list also offers **sortable
  and filterable "SLA reaction" / "SLA solution" columns** (colored status chips)
  for an at-a-glance overview. When SLA is enabled, a project **"SLA statistics"
  tab** shows KPIs and interactive, responsive charts (Chart.js, bundled locally —
  no CDN) for ticket volume, compliance, average/median response and resolution
  times, and busiest hours/weekdays, groupable by day/week/month/year.
- **Phishing detection (PhishTank + Phishing.Database)**: Optional per-project check of incoming
  mail links against a local mirror of the PhishTank database and optionally
  the Phishing.Database community feed (downloaded periodically, interval
  configurable). Microsoft SafeLinks are decoded
  locally. On a hit, links are either neutralized (ticket is created with a
  warning banner and journal note) or the mail is quarantined (moved to the
  skipped folder, no ticket) — configurable per project. Manual sync:
  `bundle exec rake redmine_expert_helpdesk:phishtank_sync`; automatic sync
  runs piggybacked on the `fetch_all` endpoint.
- **Rules**: Automation by subject/sender (set priority, tracker, category,
  assignment or ignore the mail).
- **Initial mail**: Assign a customer contact to any ticket (including
  manually-created ones) and optionally send an initial outbound email. A
  "New Helpdesk Ticket" button in the issue list and a "Send as E-Mail"
  option in the create form support this workflow.

## Screenshots

All screenshots show a demo project with synthetic data.

### Customer list

Every sender becomes a customer record, with ticket count and last contact per
customer.

![Customer list of a helpdesk project: a searchable, paginated table with name, email
address, company, phone number, ticket count and date of the last ticket](docs/screenshots/en/03-contacts.png)

### Ticket with customer context

The ticket page shows who wrote, from which mailbox, and how both SLA clocks stand.

![Ticket page with the helpdesk info bar: sender name and address, the origin mailbox and
two green SLA chips for reaction and solution time](docs/screenshots/en/04-issue-detail.png)

The sidebar adds the customer card, the customer's earlier tickets and — if the knowledge
base is enabled — proposed solutions from similar resolved tickets.

![Ticket sidebar with the customer card (name, email, company, phone, origin mailbox, list
of earlier tickets) and below it the AI assistant with proposed solutions from similar
resolved tickets, each with a match score](docs/screenshots/en/05-issue-sidebar.png)

### Replying to the customer

Replies are written in the normal Redmine note field; the helpdesk panel adds recipients
and a preview of the signature that will be appended.

![Reply panel inside the ticket edit form: a "send as email to customer" checkbox with the
recipient, To/CC/BCC fields and a preview of the signature](docs/screenshots/en/06-reply.png)

### SLA statistics

Per-project reaction and solution times, measured in working hours only.

![SLA statistics dashboard: key figures for tickets, open, closed and breached, a
compliance bar chart, monthly ticket volume, average times over time and busiest hours and
weekdays](docs/screenshots/en/01-sla-dashboard.png)

The same SLA state is available as ticket-list columns, so a queue can be sorted and
filtered by it.

![Ticket list with the additional columns Customer, SLA reaction and SLA solution, the SLA
cells shown as green, red and blue status chips](docs/screenshots/en/09-issue-list.png)

### AI usage statistics

If AI summaries or the knowledge base are enabled, every request is logged and reported.

![AI statistics dashboard: request count, token usage, success rate and latency, plus
charts for request volume, token usage over time, success versus failure, request type,
provider model and busiest times](docs/screenshots/en/02-ai-dashboard.png)

### Configuration

Mailboxes, SLA targets, AI and knowledge-base options are configured per project.

![Helpdesk tab in the project settings with sections for reply settings, SLA targets
including per-priority overrides, AI summary options, knowledge base and the mailbox
list](docs/screenshots/en/07-project-settings.png)

Each mailbox carries its own folders, defaults for new tickets, sender filters,
autoresponder and reply templates.

![Mailbox configuration form with mailbox address and folders, defaults for new tickets,
reopening rules, sender filter, auto-reply filter, autoresponder text and reply templates
including a signature preview](docs/screenshots/en/08-mailbox-form.png)

## Mail providers

Every mailbox picks its own backend in *Helpdesk → Mailbox → Mail provider*:

| Provider | Incoming | Outgoing | Typical use |
|----------|----------|----------|-------------|
| `graph` (default) | Microsoft Graph API | Graph `sendMail` | Microsoft 365 / Exchange Online |
| `imap` | IMAP | SMTP | Google Workspace, Exchange on-premises, Dovecot, Zimbra, any hoster |

Existing mailboxes keep `graph` and need **no configuration change**.

### Where credentials come from

`Credentials` on the mailbox form is an explicit switch, not a fallback chain:

- **From plugin settings** (`global`) — the mailbox uses the central application registration
  under *Administration → Plugins → Redmine expert Helpdesk*. There is exactly **one**: the
  Tenant ID / Client ID / Client Secret that Graph has always used. IMAP/SMTP mailboxes on OAuth2
  share it rather than holding a second copy. The preset and flow selected there decide which of
  the remaining fields are needed at all, and the page hides the rest.
- **Individual for this mailbox** (`mailbox`) — the mailbox uses only its own fields. The mailbox
  form hides them while the switch is on *From plugin settings*, because they have no effect there.

A mailbox uses **one source entirely**. Blank fields are deliberately *not* filled in from the
other source: a half-configured mailbox that silently authenticates against the wrong tenant is
exactly the failure this avoids.

The one thing the plugin settings do supply on top of the registration is a **default host** for
the *Other / self-hosted* preset (IMAP/SMTP host, port and encryption) — useful when every mailbox
lives on the same server. Microsoft and Google mailboxes ignore it, since their preset already
knows the hosts, and an explicit value on the mailbox always wins.

Per-mailbox secrets (passwords, client secrets, refresh tokens, service account keys) are
encrypted at rest with Rails' `secret_key_base`. Leaving a secret field empty keeps the stored
value; entering a single `-` deletes it. **Rotating `secret_key_base` makes stored secrets
unrecoverable** — they then have to be re-entered and the OAuth consent re-run.

### Authentication

OAuth2 (XOAUTH2) is the default. Three flows are supported:

| Flow | Consent | Use for |
|------|---------|---------|
| Application only (`client_credentials`) | none | Microsoft 365 IMAP with `IMAP.AccessAsApp` / `SMTP.SendAsApp` |
| One-time consent (`authorization_code`) | once per mailbox, refresh token stored | Gmail, and any other identity provider |
| Service account (`jwt_bearer`) | none | Google Workspace with domain-wide delegation |

Username/password over TLS remains selectable for servers that have no OAuth2 at all
(Dovecot, Zimbra, small hosters). Microsoft 365 no longer accepts basic authentication.

The **Callback URL** shown on the form must be registered verbatim as the redirect URI with the
identity provider — it is a single fixed path (`/helpdesk/oauth/callback`) because providers only
accept exactly registered URIs. Which mailbox is being connected travels in a signed, ten-minute
`state` parameter.

Use **Test connection** on the mailbox form to verify host, TLS and login before saving; it also
lists the folders it can see. On failure the provider's own message is shown, and **Copy message**
puts the whole of it on the clipboard — provider errors are long and the status line wraps, so
what is readable on screen is not always what you want to paste into a ticket. For Microsoft 365
the message carries Graph's error code, which is what distinguishes an `ErrorAccessDenied` (the
Exchange RBAC scope does not cover this mailbox) from a `MailboxNotEnabledForRESTAPI` (the mailbox
is inactive, soft-deleted or still hosted on-premises) — two 403s with nothing else in common.

### Recipe: Microsoft 365 over IMAP (application only)

Use this when you want IMAP/SMTP instead of the Graph API, e.g. to keep one code path for several
providers.

1. Register an app in Entra ID and grant the **application** permissions `IMAP.AccessAsApp` and
   `SMTP.SendAsApp` (admin consent required).
2. Register the service principal in Exchange Online and scope it to the mailbox:

   ```powershell
   New-ServicePrincipal -AppId <client-id> -ObjectId <object-id>
   Add-MailboxPermission -Identity "helpdesk@example.com" -User <object-id> -AccessRights FullAccess
   ```

3. In the mailbox form: provider `IMAP / SMTP`, preset **Microsoft 365**, flow
   **Application only**, and enter Tenant ID, Client ID and Client Secret (or leave
   *Credentials* on *From plugin settings* to reuse the central registration).
   Host and port fields are prefilled: `outlook.office365.com:993` and `smtp.office365.com:587`.

### Recipe: Google Workspace / Gmail (one-time consent)

1. In the Google Cloud console create an **OAuth client ID** of type *Web application* and add the
   plugin's callback URL as an authorized redirect URI.
2. Enable the scope `https://mail.google.com/` and **publish** the OAuth consent screen — refresh
   tokens issued while the screen is in *Testing* expire after 7 days.
3. In the mailbox form: provider `IMAP / SMTP`, preset **Google Workspace / Gmail**, flow
   **One-time consent**, enter Client ID and Client Secret, save, then press **Connect** and
   complete the Google consent.

Gmail maps folders to labels — moving a mail relabels it. Use `[Gmail]/…` paths for the special
folders.

For a Workspace domain you can instead use a **service account** with domain-wide delegation
(flow *Service account*, scope `https://mail.google.com/`): paste the service account address and
its PEM private key; no interactive consent is needed.

### Recipe: self-hosted server (Dovecot, Zimbra, hoster)

1. Provider `IMAP / SMTP`, preset **Other / self-hosted**.
2. Enter the IMAP and SMTP host, port and encryption (`SSL/TLS` on 993/465, `STARTTLS` on
   143/587).
3. Authentication **Username and password**, then the mailbox user and its password (an
   app password where the provider offers one). The SASL mechanism is negotiated: IMAP uses the
   `LOGIN` command unless the server advertises `LOGINDISABLED`, in which case it authenticates
   with `PLAIN` or `LOGIN`; SMTP takes the first of `PLAIN`, `LOGIN`, `CRAM-MD5` the server
   offers. Most servers only accept a password over TLS, so keep `SSL/TLS` or `STARTTLS`.
4. Only disable *Verify certificate* for a self-signed certificate on a trusted network — it is
   logged as a warning whenever it is used.

### IMAP behaviour worth knowing

- Mails are addressed by **UID** throughout, so concurrent access to the mailbox cannot mix up
  messages.
- Fetching never marks a mail as read on its own (`BODY.PEEK`); `\Seen` is set explicitly when the
  mail is moved to the processed folder. *Only fetch unread mails* is available for setups where
  moving is not possible.
- Folder names are entered as readable text with `/` as separator and translated to modified UTF-7
  and the server's own delimiter on the wire, so names like `Gelöschte Elemente` work.
- Moving uses `MOVE` (RFC 6851) when the server offers it, otherwise `COPY` + `\Deleted` +
  `UID EXPUNGE`. **A server with neither `MOVE` nor `UIDPLUS` falls back to a plain `EXPUNGE`,
  which also permanently removes other mails already flagged as deleted in the source folder.**

## Email Processing

### Flow per mailbox fetch

```
Provider (source folder) — Graph API or IMAP
        │
        ▼
  Black-/whitelist check ──── rejected ─────▶ skipped folder
        │
        ▼
  Ignore rules ───────────── matches ───────▶ skipped folder
        │
        ▼
  Download raw MIME (Graph / IMAP BODY.PEEK)
        │
        ▼
  Auto-reply filter ──────── out-of-office ─▶ skipped folder
        │                    (optional per mailbox; a sender on the
        │                     whitelist is processed anyway)
        ▼
  Phishing scan ─────────── hit + "quarantine" ─▶ skipped folder (no ticket)
        │                   (optional per project; on "neutralize" the links
        │                    are rewritten in the body and processing continues)
        ▼
  MIME preprocessing
    ├─ strip thread headers if the referenced ticket is closed and older than
    │  the mailbox's reopen_max_age_days  →  forces a NEW ticket
    ├─ strip the Auto-Submitted header on NDR/bounce mails
    │  (MailHandler would otherwise reject them as auto-replies)
    ├─ ensure In-Reply-To/References point at the ticket thread, so replies
    │  match even when the subject carries no [#id] tag
    └─ mark <img src="cid:…"> as [cid:…] when the body comes from the HTML part
       (only that copy — the .eml archived below stays the original mail)
        │
        ▼
  Redmine MailHandler ────── rejected ───────▶ skipped folder
    (create ticket or         (e.g. own address)
     append journal)
        │
        ▼
  Point the [cid:…] markers at the embedded images MailHandler stored
        │
        ├─ new ticket:  apply rules
        └─ reply:       reopen the ticket if closed (per-mailbox reopen status)
        │
        ▼
  Link contact + HelpdeskTicketInfo (contact, origin mailbox, SLA clocks)
        │
        ▼
  Create HelpdeskMessage (direction=in) + attach original mail as .eml
        │
        ▼
  Autoresponder (new tickets only, if enabled on the mailbox)
        │
        ▼
  Phishing note (only if hits or suspicions were found)
        │
        ▼
  Enqueue AI summary job (optional, async — never blocks ingestion)
        │
        ▼
  Move to processed folder, mark as read


  Any exception during processing ──▶ failed folder,
  recorded in the mailbox's last_error / last_error_at
```

**Target folders**: the flow uses three separate destinations — `processed_folder` for
successfully ingested mail, `skipped_folder` for everything rejected before a ticket exists, and
`failed_folder` for mails that raised an exception. Skipped and failed fall back to
`processed_folder` when left blank; if that is blank too, the mail stays put and is only marked as
read. Rejected mail is moved rather than left in place so it is not re-evaluated on every fetch.

**Failure isolation**: each message is processed in its own `begin`/`rescue`, so a single broken
mail never aborts the run — it lands in the failed folder, is counted in the result, and the fetch
continues with the next message. Optional steps (phishing, autoresponder, AI) are likewise
non-fatal: they log and move on rather than breaking ingestion.

### Matching email replies to existing tickets

The matching decision itself is made by **Redmine's own `MailHandler`** — the plugin supplies the
MIME data and evaluates the result. It does, however, influence the outcome in the preprocessing
step described above: it injects `In-Reply-To`/`References` so replies match even without an
`[#id]` tag in the subject, and it strips those same headers when the referenced ticket is closed
and older than the mailbox's reopen age limit, deliberately forcing a new ticket instead of
reviving a long-dead thread.

The `MailHandler` checks in this order:

1. **`In-Reply-To` / `References` header**  
   Redmine stores the Message-ID of every outgoing notification. If a matching
   ID is found in these headers, the mail is appended as a comment (journal)
   to the corresponding ticket.

2. **`[#id]` pattern in subject**  
   If the subject contains a pattern like `[#42]`, ticket #42 is looked up.
   If found, a journal entry is created; otherwise a new ticket is created.

3. **No match**  
   A new ticket is created in the configured project, using the default
   tracker, priority and status from the mailbox configuration.

> **Note**: The `MailHandler` also handles user creation and permission checks.
> `unknown_user_mode` on the mailbox controls what happens with unknown senders
> (`accept`, `create`, `ignore`).

### Tickets awaiting a response

When an inbound mail lands on an **existing** ticket, that ticket is flagged **Awaiting response**
so it does not get lost between tickets nobody is waiting on. The same happens when a reply
reopens a closed ticket — the reason is then shown as *Reopened* instead of *Customer replied*,
and the reopen itself is recorded in the ticket history.

The flag stores the timestamp of the **oldest unanswered** customer reply, so a second reply does
not make a ticket that has been waiting for days look fresh. It clears when

- an agent posts a **public** note (a private note is an internal remark, not an answer), or
- the ticket is closed — including via bulk edit or the REST API.

Four places show it:

| Surface | What you get |
| --- | --- |
| Ticket list | *Awaiting response* column (sortable, longest wait first) and filter |
| Ticket list rows | Waiting tickets get a marker on the left edge |
| Ticket-list sidebar | Counter linking to the filtered list |
| My Page | Block *Helpdesk: awaiting response* — your waiting tickets, oldest first |

Two things worth knowing:

- A customer who is a project member with the *Send customer replies* permission counts as an
  agent, so their mails never flag a ticket.
- Reopening a ticket manually after it was closed does not restore the flag — only a new inbound
  mail sets it again.

Turn the feature off under *Administration → Plugins → Redmine expert Helpdesk*.

### Embedded images

Mail clients do not put pictures into the body, they put a reference to an attached image there —
`[cid:image001.png@01DD2980.37ED1560]` in Outlook, `[image: logo.png]` in Gmail, `<img
src="cid:…">` in HTML. Redmine's `MailHandler` stores the image as a ticket attachment but keeps
the text as it is, so a mail signature used to arrive as a row of `[cid:…]` markers.

The plugin points those markers at the attachment that was just stored, using the image syntax of
the configured text formatting (`!image001.png!` for textile, `![](image001.png)` for
markdown/CommonMark) — the ticket then reads like the original mail. This covers the description of
a new ticket as well as the note of a reply.

Worth knowing:

- Only image files Redmine can display inline are linked (`bmp`, `gif`, `jpg`, `jpe`, `jpeg`,
  `png`, `webp`). A marker whose image is missing — excluded by
  *Administration → Settings → Incoming emails → Excluded attachment file names*, for instance —
  is left in place rather than silently dropped.
- If Redmine builds the ticket text from the **HTML part** (no plain-text alternative, or
  *Preferred body part* set to `html`), the `<img>` tags are converted to the same marker before
  the mail reaches `MailHandler` — Redmine's HTML-to-text conversion would otherwise drop images
  without a trace. Only the copy handed to `MailHandler` is touched; the `.eml` archived on the
  ticket is always the untouched original mail.
- The images stay regular attachments of the ticket, so nothing changes for downloads or the
  attachment list.

Turn the feature off under *Administration → Plugins → Redmine expert Helpdesk → Embedded images*.

### EML attachment and journal link

Every processed mail is stored as a `.eml` file attached to the ticket
(attachment description: *Original E-Mail*). The file is accessible via the
customer card in the ticket sidebar.

For **reply mails** (i.e. the mail is appended as a journal to an existing
ticket), a download link is additionally inserted at the beginning of the
journal comment so the original mail can be opened directly from the ticket
history.

### Customer replies from Redmine

When an agent replies via the ticket form ("Send as e-mail to customer"), the
reply is sent as a complete MIME message — through the mailbox's own backend.
For a Microsoft 365 mailbox that is the Graph API endpoint
`/users/{mailbox}/sendMail` (with `Content-Type: text/plain` + Base64-encoded
MIME body). This preserves the full MIME structure — especially for CID inline
images — because Exchange Online rewrites the HTML body when using the JSON
send method.

The plugin stores:

- an outgoing `HelpdeskMessage` with recipient To/CC/BCC and timestamp,
- the mail body corresponds to the Redmine note field (wiki markup → HTML),
  augmented with the configured header/footer template of the mailbox.

The subject is generated from the project setting *Subject template*
(default: `Re: [#{{issue.id}}] {{issue.subject}}`).

**Inline images**: Images inserted via drag & drop or paste into the notes
field appear in the recipient's mailbox as embedded inline images (CID method,
not as attachments).

**Transport choice**: Each mailbox picks one of three reply transports:

| Value | Sends through | Inline images | Files a Sent copy |
|-------|---------------|---------------|-------------------|
| `provider` (default for new mailboxes) | the mailbox's own backend — Graph API, or its own SMTP server | CID | yes |
| `graph` | Microsoft Graph, using the central app registration | CID | yes |
| `smtp` | Redmine's global SMTP settings from `configuration.yml` | Base64 data URIs | IMAP mailboxes only |

**Sender override (From)**: A mailbox on the `smtp` transport may send under an address other
than the mailbox address — *Sender override (From)* in the mailbox form; empty means "send as the
mailbox address". Two consequences worth knowing:

- `Reply-To` is **not** set by default. The usual reason for an override is a distribution list
  that became a helpdesk mailbox: the list address still exists, this mailbox is its only
  member, so replies to the list arrive here anyway and a `Reply-To` would only expose the
  internal address. Where the override address does *not* deliver back to the mailbox, tick
  *Set Reply-To to the mailbox address* — otherwise customer replies never reach the ticket.
- The relay in `configuration.yml` must be permitted to send for that address. This is an SPF /
  DMARC question on your mail infrastructure; the plugin only validates the syntax.

The field is hidden for the `provider` and `graph` transports and ignored by the model there:
both authenticate *as* the mailbox and reject a foreign sender.

`graph` is offered **only for a mailbox Microsoft actually hosts** — a Graph mailbox, or an IMAP
mailbox whose **effective** OAuth2 template is Microsoft ("Microsoft 365 over IMAP"). Effective
means the template actually in force: the mailbox's own only when *Credentials* is set to
*Individually for this mailbox*, otherwise the one from the plugin settings. Pointing a Gmail or
Dovecot mailbox at Graph would send `sendMail` for an address that does not exist in the tenant, so
the form hides the option and the model refuses it. For the same reason it is offered only when the
**central app registration is configured** — otherwise it would be a transport that fails at send
time. (A Graph mailbox is exempt from that second condition: its own backend is Graph regardless,
and requiring credentials there would make it unsavable while the Azure app is still being set up.)

Outgoing mail is filed in the mailbox's **Sent folder** so the mailbox holds both halves of the
conversation. Graph does that itself; for IMAP the plugin appends the message, taking the folder
from the server's RFC 6154 `\Sent` flag, then the mailbox's *Sent folder* field, then the preset.
If the copy cannot be filed the mail is still sent — only a warning is logged.

`smtp` is the option that needs **no mail credentials on the mailbox at all** — useful when
Redmine already has a working relay and the mailbox only has to *receive*. An IMAP mailbox on
this transport does not need an SMTP host either. The trade-off is inline images: this path
embeds them as data URIs rather than CID attachments, which some clients refuse to display.

The autoresponder uses the same transport as replies.

**Every send is logged.** Since three transports and four senders (agent reply, initial mail,
autoresponder, SLA notification) all end up as "a mail left Redmine", each one writes a single
log line naming the route it took:

```
[helpdesk] mail sent: kind=reply via="mailbox SMTP (smtp.example.com:587)" mailbox=support@example.com \
  project=support issue=#4711 to="customer@example.com" message_id=<...> subject="Re: [#4711] Printer broken"
```

A send that raises is logged as `[helpdesk] mail FAILED: …` including the exception, always at
**error** level, and the exception is re-raised as before. The severity of the success line is
configurable under *Administration → Plugins → Redmine expert Helpdesk → Logging*
(`debug` / `info` / `warn` / `error`, default `info`) — pick `debug` to keep it out of a
production log, which by default records `info` and above.

Stored recipient addresses are shown as badges in the journal headers after
page load (client-side, matched through the journal link stored in
`helpdesk_messages.journal_id`). The badge ends with the **send time**
(`HelpdeskMessage.sent_at`), just like the badge on received mails shows their
send time — so both directions of the conversation can be followed on one time
axis, independently of when the journal entry itself was saved.

**Automatic field update after sending**: Optionally, a target status and
automatic assignment to the sender can be configured in the project settings
(*Helpdesk → Reply settings*). Both are applied after a successful send,
before the ticket form is submitted. The assignment only takes effect while the
ticket is still **unassigned** — neither stored (user or group) nor picked in
the form you are about to submit — so it never overrides a routing decision
somebody has already made.

### Assigning tickets

Three settings decide who owns a ticket, in this order of precedence:

| Setting | Where | Applies |
|---------|-------|---------|
| `Assigned to:` keyword in the mail | the mail itself | Handled by Redmine's own `MailHandler`; wins over everything below. |
| Mailbox rule *Assign to* | *Helpdesk → Mailbox → Rules* | Only when the rule's condition matches subject or sender. Can target a user **or** a group. |
| **Assign new tickets to** | *Project settings → expert Helpdesk → Reply settings* | Every new ticket the mailboxes of this project create. Default: do not assign. |

**Assign new tickets to** offers the project's assignable members, split into
*Users* and *Groups*. Groups appear only while *Allow issue assignment to
groups* is enabled under *Administration → Settings → Issue tracking* — that is
the same list the ticket form itself offers, so a selectable assignee is always
one Redmine accepts. If the selected user or group later loses its role or
leaves the project, it is silently skipped instead of producing invalid tickets.

All three apply to **new** tickets only. A reply never re-assigns a ticket,
except through *Assign ticket to me after reply* above, and that one only fires
while the ticket is unassigned.

### Quoting prior content

Next to the formatting icons of the note editor sits a **Quote** button with
three entries. Each appends its text at the end of the note field, separated by
a blank line — nothing you already typed is overwritten.

| Entry | What it quotes |
|-------|----------------|
| Original email | The ticket description, i.e. the mail `MailHandler` turned into the ticket. Inline images have already been resolved by then, so the quote matches what you see on the ticket. |
| Complete conversation | The description plus every public journal note, oldest first, each with its author and timestamp. |
| Email conversation | The description plus only those notes that belong to a mail actually received from or sent to the customer. |

Three rules worth knowing:

- **Private notes are never quoted**, not even for agents who hold
  `view_private_notes`. The result is meant for a customer, so the only relevant
  question is whether the customer may see it. Private AI summaries drop out for
  the same reason.
- **The plugin's own bookkeeping notes are skipped** in *Complete conversation* —
  "autoresponder sent", "phishing links removed". They are public and written by
  the anonymous user, but carry no `HelpdeskMessage`; a real customer mail always
  does, even when `MailHandler` files it under the anonymous user.
- **An outgoing mail whose journal link was never established cannot be quoted**
  in *Email conversation*. `helpdesk_messages` stores no message body, so a row
  without `journal_id` — the autoresponder and the initial mail of an outgoing
  ticket — has no text of its own. For those tickets the description *is* the
  mail that was sent, and it is always included.

Entries are separated by a horizontal rule (`---`), so a long history stays
skimmable while scrolling. Very long histories are capped (50 entries / 60 000
characters) so the note field stays editable; the toolbar reports that entries
were left out.

Images referenced in the note — including the ones a quote brings along from the
original mail — are sent as inline parts, so the customer sees the pictures and
not an empty box.

### Answer templates

Since support cases repeat, standard answers can be stored as templates and
inserted from a **Templates** button next to the Quote button. A project's own
templates are listed first, then the global ones, each ordered by position and
name; a project can therefore override a central wording by reusing its name.

- **Global templates**: *Administration → Plugins → Redmine expert Helpdesk →
  Answer templates*. Admins only.
- **Project templates**: project settings, tab *expert Helpdesk*, section
  *Answer templates*. Requires `manage_helpdesk`.

The content understands the same macros as autoresponder, header/footer and
subject templates (see [Template Macros](#template-macros)). They are expanded on
the server at insertion time, because a macro needs the ticket, its customer and
the acting user. On a ticket without a linked customer the contact macros simply
render empty — templates still work there, as does quoting.

Inserting a quote or a template requires the `send_helpdesk_reply` permission,
the same one that gates the reply form.

## Contacts / Customer List

Senders are automatically saved as `HelpdeskContact` records on the first
mailbox fetch and assigned to the project.

### Ticket list columns

The issue list offers two optional, sortable columns: **Customer** (the
contact's display name) and **Customer email** (the plain email address —
useful where display names are long or unclear). Both show the ticket's
customer: the contact linked on mail ingest, or the one an agent assigned.
The **Customer** filter matches name or email and covers both columns.
Tickets without a customer (e.g. created by an agent without assigning one)
stay blank.

### Customer list (project tab "Kunden")

- Tabular overview of all contacts with name, email, company, phone, ticket
  count and date of last message.
- **Pagination**: The list is shown page by page. A per-page selector
  (10 / 25 / 50 / 100) at the top right; default configurable under
  *Administration → Plugins → Display settings → Entries per page*.

### Customer profile (edit view)

- Name, company, phone and internal notes are editable.
- List of the most recently linked tickets (newest first).
  The number of displayed tickets is configurable under
  *Administration → Plugins → Display settings → Max. tickets in customer profile*
  (default: 10). When there are more tickets a note
  "Showing the N most recent of X tickets total" is shown.

![Customer profile: editable fields for name, company, phone and notes, below them a table
of the customer's previous tickets with number, subject, status and last
update](docs/screenshots/en/10-contact-profile.png)

### Contact display on the ticket page

- **Info bar** below the ticket fields: sender name, email and company, link
  to the original EML file.
- **Sidebar**: Customer card with full profile, link to the customer profile
  and history of sent replies (To/CC/BCC, timestamp, attachments).

### Assigning a contact to an existing ticket

Any ticket — including ones created manually without an incoming email — can
have a customer contact assigned via the sidebar. The "Kunde zuordnen" form
in the sidebar allows:

- Looking up or creating a contact by email address (with autocomplete).
- Optionally sending an initial outbound email to the contact (mail body
  defaults to the ticket description; configurable header/footer templates
  are applied).
- Just assigning without sending (leaves a `direction=init` message as the
  contact link).

## Triggering a Mail Fetch

There is intentionally no built-in scheduler. Two options:

1. **Button**: *Project settings → expert Helpdesk → "Fetch mails now"*
   (permission *Fetch helpdesk mails*).
2. **HTTP endpoint** for curl/cron (all active mailboxes):

   ```bash
   curl "https://redmine.example.com/helpdesk/fetch_all?key=API-KEY"
   ```

   The API key is configured in the plugin settings. Without a configured key
   the endpoint is disabled. The response is a JSON summary.

## Triggering the SLA Check

The SLA breach check runs on its own dedicated endpoint (independent of the
mail fetch), so it can be scheduled by a separate cronjob:

```bash
curl "https://redmine.example.com/helpdesk/sla_check?key=SLA-API-KEY"
```

It is secured by its **own** API key (*SLA API key* plugin setting, separate
from the mail-fetch key); an empty key disables the endpoint. Overlapping runs
are prevented by a cache lock — a concurrent call returns `{"skipped": true}`
instead of processing again. The response is a JSON summary
(`{"checked_at": …, "notified": N}`).

## Plugin Settings

Under *Administration → Plugins → Redmine expert Helpdesk* — or, as a shortcut, via the
**expert Helpdesk** entry in the Administration menu, which links here directly:

| Setting | Description |
|---------|-------------|
| Tenant ID | Azure directory ID (GUID) — Graph mailboxes |
| Client ID | App registration ID (GUID) — Graph mailboxes |
| Client Secret | App registration secret — Graph mailboxes |
| Default credentials for IMAP/SMTP mailboxes | Preset, flow, tenant/client/secret, authorization and token URL, scope, and default IMAP/SMTP hosts, ports and encryption. Used by every mailbox whose *Credentials* is set to *From plugin settings* — see [Mail providers](#mail-providers). |
| API Key (mail fetch) | Secures the global fetch endpoint |
| API Key (SLA check) | Secures the `helpdesk/sla_check` endpoint |
| Show embedded images in the ticket | Replaces the `[cid:…]` markers of an incoming mail with the image itself (default: on) — see [Embedded images](#embedded-images) |
| Entries per page | Default page size of the customer list (default: 25) |
| Max. tickets in customer profile | Tickets shown in the customer detail view (default: 10) |

## REST API

A REST API (JSON and XML) for automations, following Redmine's conventions —
enable *Administration → Settings → API*, authenticate with `X-Redmine-API-Key`,
and append `.json`/`.xml`. **Full reference with all parameters and examples:
[API.md](API.md).**

| Method | Path |
|--------|------|
| GET / POST | `/projects/:id/helpdesk/contacts.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/contacts/:id.{json,xml}` |
| GET / POST | `/projects/:id/helpdesk/tickets.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/tickets/:id.{json,xml}` |
| GET / PUT | `/projects/:id/helpdesk/settings.{json,xml}` |
| GET / POST | `/projects/:id/helpdesk/mailboxes.{json,xml}` |
| GET / PUT / DELETE | `/helpdesk/mailboxes/:id.{json,xml}` |
| POST | `/helpdesk/mailboxes/:id/test_connection.{json,xml}` |

Mailboxes require `manage_helpdesk` for reading as well as writing, since their
configuration exposes mail hosts, usernames and OAuth client/tenant ids. Their secrets
(`mail_password`, `oauth_client_secret`, `oauth_sa_key`) are **write-only** — responses
report only whether one is stored, and sending `"-"` clears it.

```bash
# List helpdesk tickets of project 42
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"

# Create a ticket and assign a customer by email
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"Printer down","tracker_id":1,"contact_email":"jane@acme.example"}}' \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"
```

## AI summaries

When a ticket is created from an incoming mail (and optionally on follow-up/journal
replies), the plugin can ask an AI provider to summarize the customer's actual concern and
post it as a **private (internal) journal note** — useful for hard-to-parse mails or
forwarded threads where the relevant information is scattered. Disabled by default, opt-in
per project.

> **AI usage statistics.** Because AI features call external APIs and carry a cost/usage risk,
> every AI call (summaries, KB extraction, embeddings, RAG retrieval) is logged to
> `helpdesk_ai_requests` — including failures and latency. A per-project **"AI statistics"** tab
> (same time-frame selector and totals-at-a-glance layout as the SLA dashboard) breaks usage down
> by volume, tokens, request type, provider/model, success rate and busiest times. The tab is
> restricted to the **global** permission `view_helpdesk_ai_statistics`: grant it to a role (e.g.
> one you name *ai-admin*) and those users see the tab on every helpdesk project where at least
> one of the AI features or the knowledge base is enabled — with both switched off centrally the
> tab is hidden and the page answers 403. Tokens only — no monetary cost is computed yet.

**Central configuration** (*Administration → Plugins → Redmine expert Helpdesk*):
- **Provider** — OpenAI (Chat Completions), Anthropic (Messages), or **Custom** (any
  OpenAI-compatible base URL, e.g. self-hosted Ollama / vLLM / LocalAI / LM Studio).
- **API key**, **endpoint** (blank = provider default; required for Custom), **model**.
- **Default prompt** (a sensible German default is shipped) + limits (max input characters
  / output tokens / timeout).
- **Min. input characters** (default 200) — mails shorter than this skip the AI call
  entirely, since a two-line mail summarizes to itself. The private note then just states
  that the summary was skipped and why (it still carries the 🤖 badge, with 0 tokens).
  `0` disables the check and always summarizes.
- **Log level for AI diagnostics** (*Logging* section, default `debug`, `off` to silence) —
  the severity at which the plugin logs the measured input length and the resulting decision:
  `[helpdesk][ai][debug] length issue=#42 chars=87 min=200 images=0 decision=skip`. Rails logs
  at `info` in production and would drop a `debug` line, so the line is raised to the logger's
  own level and carries its severity in the prefix instead — picking `debug` never silently
  logs nothing.

**Per-project configuration** (project *Settings → expert Helpdesk*, shown when AI is enabled
centrally):
- Enable summaries for the project; choose **scope** (initial mail only, or initial mail
  and replies).
- **Prompt mode** — *inherit* the central prompt, *extend* it, or *override* it with a
  project-specific prompt.
- **Attachments** — independently choose what is sent to the AI: filenames/metadata,
  extracted text (PDF via optional `pdf-reader`, text files), and/or images (requires a
  vision-capable model).
- **Minimum image size** — images below this many KB, or smaller than 64x64 pixels, are not
  sent to the model. Signature logos, social icons and tracking pixels hang off nearly every
  mail: they cost vision tokens for nothing and push the real screenshot out of the small
  per-request image budget. An image whose size cannot be determined is kept, and one that is
  embedded inline *and* whose bytes recur on other tickets is dropped as a signature graphic.
  Applies to images only — attachment text and metadata are unaffected. `0` disables it;
  default 15 KB.
- **Ticket history** — optionally send the whole conversation (description + all notes)
  instead of only the triggering mail, and optionally include **private notes** (off by
  default; those internal notes are then sent to the provider too). The plugin's own AI
  summary notes are always excluded.

Summaries run **asynchronously** (ActiveJob `HelpdeskAiSummaryJob`), so AI latency or
failures never block or slow the mail-fetch cycle; if the call fails, the ticket is still
created and the error is only logged. The **token usage** of each summary is shown as a 🤖
badge in the note's journal header (tooltip: input/output tokens and model), mirroring the
to/cc/bcc recipient badges. You can **regenerate** a summary on demand from the **AI Assistant**
card in the ticket's Helpdesk sidebar (a dedicated card below the customer card, shown only when
AI/KB is enabled for the project) — handy after a failed run or for tickets that predate the
feature. The regenerate button appears only when *Generate AI summaries for this project* is on.

> **Data protection:** incoming mail content and the selected attachments are sent to the
> configured provider. For a fully on-premise flow, use the **Custom** provider pointed at
> a self-hosted, OpenAI-compatible endpoint. The feature is off by default and opt-in per
> project.

## Completeness check for incoming mail

A ticket that arrives as *"printer is broken"* — no screenshot, no error message, no system
name — costs an agent the first cycle just to write "please tell us more", and that cycle runs
against the SLA. The plugin can evaluate the **first** mail of a new ticket and, when it does not
carry enough to start working, mail the customer a templated follow-up automatically.

**What happens on "not enough information":**

1. A follow-up mail goes to the customer, listing the missing details. It carries
   `In-Reply-To`/`References` of the original mail, so the answer threads back onto the same ticket.
2. A journal note records that the follow-up was sent and what was asked for. Public by default,
   so the agent and the customer see the same record; a project can make it an internal note
   instead (**Journal note about the follow-up**).
3. Optionally the ticket is moved to a configured status (e.g. *Waiting for customer*).

**Two modes**, chosen per project:

| Mode | How it decides | Needs AI |
|---|---|---|
| **Rule-based** | Minimum length (characters and/or words), "an attachment is required", a list of expected terms, and a threshold: how many of these rules must fail before the customer is asked. | No |
| **AI-powered** | The model returns a verdict plus the concrete details it found missing; those go straight into the follow-up mail. | Yes |

The default AI prompt asks for a **screenshot** when the problem is software (an application, a
web portal, an error dialog) and a **photo** when it is hardware (a device, printer, till, display,
cabling — ideally showing the type plate or the display). When it cannot tell which of the two it
is, it asks for the affected system instead of guessing. The model is also told which files are
already attached, so it never asks for a screenshot the customer has already sent.

Quoted history, forwarded headers (`-----Original Message-----`, `Am … schrieb …:`) and
signatures are stripped before anything is measured, so a two-word reply under a long quoted
thread does not pass as a detailed report.

**Images below a minimum size do not count as evidence** in either mode. Signature logos and
tracking pixels hang off nearly every mail and would otherwise satisfy "an attachment is required"
every single time. The threshold is per project (15 KB by default, `0` switches it off) and applies
to **images only** — a small log file or PDF is evidence of a different kind and still counts. When
an attachment reports no size at all, it is kept rather than discarded.

**Central configuration** (*Administration → Plugins → Redmine expert Helpdesk*):
- **Enable completeness check** — the master switch. Off by default; while it is off, no project
  runs the check no matter how it is configured.
- **Subject / text of the follow-up mail** — templates. All the usual macros work, plus
  `{{missing_info}}`, which inserts the rendered list of missing details.
- **Check prompt** — the default prompt for the AI mode.

**Per project** (*Project → Settings → expert Helpdesk*):
- **Mode** — *Off* (default), *Rule-based* or *AI-powered*.
- The rule values: minimum characters, minimum words, "require an attachment", **minimum image
  size (KB)**, expected terms (one per line), and the threshold. A value of `0` switches an
  individual rule off.
- **Prompt mode** for the AI check — inherit / extend / override the central prompt, exactly like
  the AI summary prompt.
- **Subject / text** — optional per-project override of the central templates.
- **Journal note about the follow-up** — *Public* (default; the customer sees it too) or
  *Internal* (agents with the "View private notes" permission only). The mail itself is unaffected.
- **Status after the follow-up** — optional; blank leaves the status untouched. **Only open
  statuses are offered**, see the SLA note below.

**Safety properties worth knowing:**

- **New tickets only.** A reply in a running conversation never triggers a follow-up.
- **At most one follow-up per ticket.** A re-fetch, a reopen or a manual re-run cannot mail the
  same customer twice — the counter lives on `helpdesk_ticket_infos`. The follow-up is *claimed*
  inside a row lock **before** the mail is sent, so two jobs racing on the same ticket (duplicate
  enqueue, retry overlap) cannot both get through. If the send then fails the claim is kept on
  purpose: a missed follow-up is repairable by an agent, a duplicate one is not.
- **The AI mode fails closed.** The model has to answer with JSON
  (`{"complete": true|false, "missing": [...]}`); anything unparseable, an API error, or
  "incomplete" without a single reason all count as *complete*, so a garbled response never mails
  a customer.
- **It never touches the SLA.** The follow-up note does not stop the reaction clock — it is the
  plugin talking, not an agent reacting — and the automatic status change can never close the
  ticket. That second part matters: every SLA reader treats a closed ticket as *both* reaction-done
  and solution-done, so a "waiting for customer" status that happened to be flagged as closed would
  have silently marked both clocks met before the customer had even answered. Closed statuses are
  therefore not offered in the select, rejected on save, and refused again at the write.
- **It never breaks ingestion.** The check runs in a background job after the mail has been
  processed; every failure is logged and swallowed.
- AI-mode calls are logged to `helpdesk_ai_requests` as request type `completeness` and show up in
  the per-project AI statistics.

## Knowledge base (RAG)

Resolved tickets can be turned into a **per-project knowledge base**: an AI call extracts a
`{problem, solution}` pair from each closed ticket, embeds the problem, and stores it in an
external vector database. When a new mail arrives, the summary job searches **only that
project's** knowledge for similar solved tickets and — if enough clear the score threshold —
adds a **proposed solution** to the summary and/or a sidebar panel. Disabled by default.

**Central configuration** (*Administration → Plugins*):
- **Vector store** (`kb_backend`): **Qdrant** (REST, no extra gem) or **Postgres + pgvector**
  (needs the `pg` gem in your deployment; `PgvectorStore` loads it via a guarded `require`).
- **Embeddings**: provider (OpenAI or a self-hosted OpenAI-compatible endpoint — Anthropic has
  no embeddings API), model, endpoint, key (blank reuses the summary key for the same provider).
- Extraction prompt and retrieval params (Top-K, min. score, min. results).

**Per-project configuration** (project *Settings → expert Helpdesk*, shown when the KB is enabled):
- **Contribute** (`kb_ingest_mode`): off / **auto** (ingest on close if a solution was found) /
  **manual** (close creates a *pending* entry; approve it from the ticket sidebar).
- **Show proposed solutions** (`kb_proposal_display`): off / summary note / sidebar panel / both.

**Isolation:** each project has its own vector namespace (Qdrant collection / enforced
`project_id` filter), so a project never retrieves another project's knowledge.

**Batch:** `rake redmine_expert_helpdesk:kb_backfill` ingests existing closed tickets;
`kb_reembed` rebuilds the vectors after an embedding-model change.

**Setup:** run a vector service reachable from Redmine — e.g. a `qdrant/qdrant` container
(`http://qdrant:6333`) or a `pgvector/pgvector` Postgres — and point the plugin settings at it.

> **Data protection:** problem/solution text is sent to the embeddings provider and stored in
> the vector DB. Use a self-hosted embeddings endpoint for a fully on-premise flow.

## Tests

The plugin ships MiniTest unit and integration tests (`test/`). They require a
Redmine environment (they load Redmine's own test helper and fixtures), so they
run inside a Redmine checkout with the plugin in `plugins/redmine_expert_helpdesk`:

```bash
# All plugin tests
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test

# A single file / a single test
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb -n test_reaction_deadline
```

**Continuous integration:** [`.github/workflows/ci.yml`](.github/workflows/ci.yml)
runs the full suite on every push and pull request. A build matrix checks out each
supported Redmine version fresh, copies the plugin in, migrates a clean MariaDB and
runs the tests — so all versions are covered in an isolated, reproducible state:

| Redmine | Ruby | Rails |
|---------|------|-------|
| 5.1-stable | 3.2 | 6.1 |
| 6.0-stable | 3.3 | 7.2 |
| 6.1-stable | 3.3 | 7.2 |
| 7.0-stable | 3.4 | 8.1 |

**Docker image smoke test:** [`.github/workflows/docker-image.yml`](.github/workflows/docker-image.yml)
additionally boots the plugin inside the **official `redmine` Docker images** used in
deployment (tags `5.1`, `6.0`, `6.1`, `7.0`). Per tag it starts the official image against a fresh
MariaDB, mounts the plugin read-only, migrates via `REDMINE_PLUGINS_MIGRATE=1`, and asserts
Redmine serves `/login` (HTTP 200) with the plugin loaded — catching `init.rb` load,
migration or gem-version issues specific to the shipped image. Add `7.0`/`7` to the matrix
once the official image publishes a Redmine 7 tag.

## Azure App Registration (one-time setup)

The following steps can be performed manually via the Azure Portal, via
PowerShell (Microsoft Graph PowerShell SDK + Exchange Online PowerShell) or
via Terraform (provider `hashicorp/azuread`).

> 💡 `scripts/setup-azure-app.ps1` in this repository runs steps 1–4 in one go
> (repo-internal tooling, not part of the release archives). It is re-runnable:
> existing resources are reused, and a later run adds further mailboxes to the
> RBAC scope from step 4 — see [Adding further mailboxes later](#adding-further-mailboxes-later).
>
> [`scripts/README.md`](scripts/README.md) explains how the two permission layers
> interact and compares the four mailbox scope options — in particular **who is able
> to onboard the next mailbox** under each of them, which ranges from "an Exchange
> Administrator has to run the script" to "whoever creates the shared mailbox sets one
> attribute". Worth reading before picking one in step 4b.

---

### Step 1 – Register the app

**PowerShell**

```powershell
Connect-MgGraph -Scopes "Application.ReadWrite.All"

$app = New-MgApplication `
  -DisplayName    "redmine-helpdesk" `
  -SignInAudience "AzureADMyOrg"   # Single Tenant

# Create Service Principal (required for Admin Consent)
$sp = New-MgServicePrincipal -AppId $app.AppId

Write-Host "AppId (Client ID):  $($app.AppId)"
Write-Host "Object ID (SP):     $($sp.Id)"
Write-Host "Tenant ID:          $((Get-MgContext).TenantId)"
```

**Terraform**

```hcl
terraform {
  required_providers {
    azuread = { source = "hashicorp/azuread", version = "~> 3.0" }
  }
}

data "azuread_client_config" "current" {}

resource "azuread_application" "redmine_helpdesk" {
  display_name     = "redmine-helpdesk"
  sign_in_audience = "AzureADMyOrg"
}

resource "azuread_service_principal" "redmine_helpdesk" {
  client_id = azuread_application.redmine_helpdesk.client_id
}
```

---

### Step 2 – Grant API permissions and admin consent

Required Application Permissions (not Delegated):
- `Mail.ReadWrite` – read and move mails
- `Mail.Send` – send autoresponder / customer replies

**PowerShell**

```powershell
# Requires: "Application.ReadWrite.All" + "AppRoleAssignment.ReadWrite.All"
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

$graphAppId      = "00000003-0000-0000-c000-000000000000"
$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

Update-MgApplication -ApplicationId $app.Id `
  -RequiredResourceAccess @(
    @{
      ResourceAppId  = $graphAppId
      ResourceAccess = @(
        @{ Id = $mailReadWriteId; Type = "Role" }
        @{ Id = $mailSendId;      Type = "Role" }
      )
    }
  )

$graphSp = Get-MgServicePrincipal -Filter "AppId eq '$graphAppId'"

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $sp.Id `
  -PrincipalId        $sp.Id `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $mailReadWriteId

New-MgServicePrincipalAppRoleAssignment `
  -ServicePrincipalId $sp.Id `
  -PrincipalId        $sp.Id `
  -ResourceId         $graphSp.Id `
  -AppRoleId          $mailSendId
```

**Or: Azure CLI**

```bash
az login
az ad app permission admin-consent --id <APPLICATION-ID>
```

**Or: Azure Portal**

1. Azure Portal → *Entra ID → App registrations* → `redmine-helpdesk`
2. *API permissions* → *Grant admin consent for [Tenant]* → Confirm

**Terraform**

```hcl
data "azuread_application_published_app_ids" "well_known" {}

data "azuread_service_principal" "msgraph" {
  client_id = data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph
}

resource "azuread_application" "redmine_helpdesk" {
  display_name     = "redmine-helpdesk"
  sign_in_audience = "AzureADMyOrg"

  required_resource_access {
    resource_app_id = data.azuread_application_published_app_ids.well_known.result.MicrosoftGraph

    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["Mail.ReadWrite"]
      type = "Role"
    }
    resource_access {
      id   = data.azuread_service_principal.msgraph.app_role_ids["Mail.Send"]
      type = "Role"
    }
  }
}

resource "azuread_app_role_assignment" "mail_readwrite" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Mail.ReadWrite"]
  principal_object_id = azuread_service_principal.redmine_helpdesk.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}

resource "azuread_app_role_assignment" "mail_send" {
  app_role_id         = data.azuread_service_principal.msgraph.app_role_ids["Mail.Send"]
  principal_object_id = azuread_service_principal.redmine_helpdesk.object_id
  resource_object_id  = data.azuread_service_principal.msgraph.object_id
}
```

---

### Step 3 – Create a client secret

**PowerShell**

```powershell
$secret = Add-MgApplicationPassword -ApplicationId $app.Id `
  -PasswordCredential @{
    DisplayName = "redmine-helpdesk-secret"
    EndDateTime = (Get-Date).AddYears(1)
  }

# Value is shown only once — save it immediately!
Write-Host "Client Secret: $($secret.SecretText)"
```

**Terraform**

```hcl
resource "azuread_application_password" "redmine_helpdesk" {
  application_id = azuread_application.redmine_helpdesk.id
  display_name   = "redmine-helpdesk-secret"
  end_date       = "2027-06-16T00:00:00Z"  # adjust on rotation
}

output "tenant_id"     { value = data.azuread_client_config.current.tenant_id }
output "client_id"     { value = azuread_application.redmine_helpdesk.client_id }
output "client_secret" { value = azuread_application_password.redmine_helpdesk.value; sensitive = true }
```

---

### Step 4 – Restrict mailbox access (important!)

`New-ApplicationAccessPolicy` is deprecated. Use **Exchange Online Application
RBAC** instead (Exchange Online PowerShell as Exchange Administrator). Terraform
is not supported for Exchange Online RBAC.

**PowerShell**

```powershell
Connect-ExchangeOnline

# 4a. Register the Service Principal in Exchange Online.
#     AppId    = "Application ID"  from Entra ID → Enterprise applications
#     ObjectId = "Object ID"       from Entra ID → Enterprise applications
#     (NOT the IDs from "App registrations" — they are different!)
New-ServicePrincipal `
  -AppId       "<CLIENT-ID>" `
  -ObjectId    "<ENTERPRISE-OBJECT-ID>" `
  -DisplayName "Redmine Helpdesk"

# 4b. Restrict the management scope to the helpdesk mailboxes.
#
#     Option A: all mailboxes whose address ends with @helpdesk.example.com
New-ManagementScope `
  -Name "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -like '*@helpdesk.example.com'"
#
#     Option B: members of a mail-enabled security group
#     $dn = (Get-Group "helpdesk-mailboxes@example.com").DistinguishedName
New-ManagementScope `
  -Name "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "MemberOfGroup -eq '<GROUP-DN>'"
#
#     Option C: custom recipient attribute (e.g. CustomAttribute1)
New-ManagementScope `
  -Name "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "CustomAttribute1 -eq 'Redmine'"

# 4c. Assign roles.
$sp = Get-ServicePrincipal -Identity "Redmine Helpdesk"
New-ManagementRoleAssignment `
  -App  $sp.ObjectId `
  -Role "Application Mail.ReadWrite" `
  -CustomResourceScope "Redmine-Helpdesk-Mailboxes"
New-ManagementRoleAssignment `
  -App  $sp.ObjectId `
  -Role "Application Mail.Send" `
  -CustomResourceScope "Redmine-Helpdesk-Mailboxes"

# 4d. Test access (InScope must be true).
Test-ServicePrincipalAuthorization `
  -Identity "Redmine Helpdesk" `
  -Resource helpdesk@example.com | Format-Table
```

> ⚠️ **Important — remove Entra permissions**: After the EXO RBAC assignment,
> the Graph permissions `Mail.ReadWrite` and `Mail.Send` in Entra ID (Step 2)
> **must be revoked**. Otherwise both grants are additive and the scope
> restriction does **not** apply — the app can then access all mailboxes in
> the tenant regardless of the defined scope.

**PowerShell — remove Entra app permissions**

```powershell
Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

$sp = Get-MgServicePrincipal -Filter "DisplayName eq 'redmine-helpdesk'"

$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
  Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) } |
  ForEach-Object {
    Remove-MgServicePrincipalAppRoleAssignment `
      -ServicePrincipalId  $sp.Id `
      -AppRoleAssignmentId $_.Id
  }

Write-Host "Done. Entra permissions removed."
```

Afterwards check in the Azure Portal under *App registrations →
redmine-helpdesk → API permissions*: the entries should appear as
*Not granted* or be absent entirely. From this point only the EXO RBAC scope
from Step 4 applies.

Full documentation: [Exchange Online Application RBAC](https://learn.microsoft.com/en-us/exchange/permissions-exo/application-rbac)

---

### Step 5 – Enter credentials in Redmine

In Redmine under *Administration → Plugins → Redmine expert Helpdesk* enter
Tenant ID, Client ID and Client Secret.

---

### Adding further mailboxes later

Every new project brings another helpdesk mailbox. Only the RBAC scope from
step 4 has to grow — the app registration, client ID and client secret stay as
they are, so nothing changes in the Redmine configuration.

With the script (recommended — it reads the current scope, merges the new
address in and leaves every other resource untouched):

```powershell
# Preview first: prints the old and the new filter, writes nothing
./scripts/setup-azure-app.ps1 -MailboxEmailList "sales@example.com" -WhatIf

./scripts/setup-azure-app.ps1 -MailboxEmailList "sales@example.com"

# and to revoke access to a mailbox again
./scripts/setup-azure-app.ps1 -RemoveMailboxEmailList "sales@example.com"
```

No names are needed here even if your setup was created under different ones:
the script tags the app registration (`RedmineExpertHelpdesk`) and finds it by
that tag, resolves the service principal from the AppId, and reads the scope to
extend off the app's existing role assignments. A setup made by hand from the
recipes above is stamped with the tag the first time the script runs against it
— pass `-AppDisplayName` on that first run so it knows which app is yours. See
[`scripts/README.md`](scripts/README.md#how-a-re-run-finds-the-installation).

A separate installation for a dev stack (its own app registration, so the dev
plugin cannot reach the live mailboxes) is `-Environment DEV`, which derives its
own tag, app name and scope name — nothing collides, and the live installation
is untouched:

```powershell
./scripts/setup-azure-app.ps1 -Environment DEV `
    -MailboxEmailList "helpdesk-dev@example.com" -TestMailbox "helpdesk-dev@example.com"
```

By hand it depends on the scope option chosen in step 4b. With **option A**
(domain suffix) nothing has to be done at all as long as the new mailbox lives
in that domain. With **option B** (security group) or **option C**
(CustomAttribute1) the scope itself stays untouched — only the mailbox is
enrolled:

```powershell
Add-DistributionGroupMember -Identity "helpdesk-mailboxes@example.com" -Member "sales@example.com"
# or
Set-Mailbox -Identity "sales@example.com" -CustomAttribute1 "Redmine"
```

If the scope enumerates the addresses explicitly (the script's default), the
filter has to be rewritten. `Set-ManagementScope` *replaces* it, so read the
current one first and list the existing addresses again:

```powershell
Get-ManagementScope -Identity "Redmine-Helpdesk-Mailboxes" | Format-List RecipientFilter

Set-ManagementScope -Identity "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -eq 'helpdesk@example.com' -or PrimarySmtpAddress -eq 'sales@example.com'"
```

Afterwards verify the new mailbox — Exchange Online needs a moment to
replicate the change, so `InScope: False` right after the update is not yet a
failure:

```powershell
Test-ServicePrincipalAuthorization -Identity <object-id> -Resource "sales@example.com" | Format-Table
```

> ⚠️ Do **not** re-grant the Entra permissions from step 2 when adding a
> mailbox. They are additive to the RBAC scope, so the app would regain access
> to every mailbox in the tenant. The script skips step 2 on an existing app
> registration for exactly this reason.

---

## Installation

### From a release (recommended)

Download the latest `redmine_expert_helpdesk-<version>.zip` (or `.tar.gz`) from the
repository's [**Releases**](https://github.com/expertZentrale/redmine_expert_helpdesk/releases)
page and extract it into your Redmine `plugins/` directory (the archive already contains a
top-level `redmine_expert_helpdesk/` folder), then migrate and restart:

```bash
cd /path/to/redmine/plugins
unzip redmine_expert_helpdesk-<version>.zip          # → plugins/redmine_expert_helpdesk/
cd /path/to/redmine
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=production
# restart Redmine
```

### From source (deploy repo)

The plugin lives in `plugins/redmine_expert_helpdesk` and is copied into the
image via the Dockerfile. Migrations run automatically on container start when
`REDMINE_PLUGINS_MIGRATE=1` is set, otherwise manually:

```bash
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

### Cutting a release (maintainers)

Releases are **tag-driven**, and `init.rb` is the single source of truth for the version. First
bump the version in `init.rb` and commit it, then push a matching semver tag:

```bash
# 1. set `version '1.2.0'` in init.rb, then:
git commit -am "release 1.2.0" && git push origin main
# 2. tag the same commit and push the tag:
git tag v1.2.0 && git push origin v1.2.0
```

The [`release.yml`](.github/workflows/release.yml) workflow then **verifies** that the `init.rb`
version matches the tag (and fails if not), builds the `.zip`/`.tar.gz` archives, and publishes a
GitHub Release with notes taken from the CHANGELOG entries added since the previous tag. Keep the
CHANGELOG current so the notes are complete. Nothing is published on normal pushes — only on tags.

Then enable the **expert Helpdesk** module in the project and assign permissions to
roles:

| Permission | Description |
|------------|-------------|
| Manage helpdesk mailboxes | Mailbox configuration, folders, rules |
| Fetch helpdesk mails | "Fetch mails now" button |
| Send customer replies | Reply form + contact autocomplete + initial mail |
| View helpdesk info | Info bar and sidebar on the ticket page |
| Manage contacts | Customer list and customer profile |

No additional gems required (Ruby standard library only).

---

## Template Macros

Usable in autoresponder, reply and subject templates. Both notations are
accepted:

### Ticket

| Macro | Short form | Meaning |
|---|---|---|
| `{{issue.id}}` | `{{ticket_id}}` | Ticket number |
| `{{issue.subject}}` | `{{ticket_subject}}` | Ticket title |
| `{{issue.url}}` | `{{ticket_url}}` | Link to the ticket |
| `{{issue.status}}` | – | Status name |
| `{{issue.priority}}` | – | Priority name |
| `{{issue.tracker}}` | – | Tracker name |
| `{{issue.author}}` | – | Author |
| `{{issue.assignee}}` | – | Assignee (empty if unassigned) |
| `{{issue.category}}` | – | Category |
| `{{issue.version}}` | – | Target version |
| `{{issue.start_date}}` | – | Start date, in the user's date format |
| `{{issue.due_date}}` | – | Due date |
| `{{issue.created_on}}` | – | Created on |
| `{{issue.updated_on}}` | – | Last updated |
| `{{issue.done_ratio}}` | – | Progress, e.g. `40%` |
| `{{issue.description}}` | – | Ticket description |
| `{{issue.parent_id}}` | – | Parent ticket id |

### Customer

| Macro | Short form | Meaning |
|---|---|---|
| `{{contact.name}}` | `{{contact_name}}` | Customer name |
| `{{contact.email}}` | `{{contact_email}}` | Customer email |

### Replying agent

Resolved from the user actually sending the reply, which makes these usable
for signatures.

| Macro | Short form | Meaning |
|---|---|---|
| `{{user.name}}` | `{{user_name}}` | Display name |
| `{{user.firstname}}` | – | First name |
| `{{user.lastname}}` | – | Last name |
| `{{user.login}}` | – | Login |
| `{{user.mail}}` | – | Email address |

### Project

| Macro | Short form | Meaning |
|---|---|---|
| `{{project.name}}` | `{{project_name}}` | Project name |
| `{{project.identifier}}` | – | Project identifier |

### Issue custom fields

Custom fields are **not** available by default. An administrator enables them
individually under *Administration → Plugins → Helpdesk → Custom fields as
macros*; only enabled fields expand. Each one can be addressed two ways:

| Notation | Example | Note |
|---|---|---|
| By id | `{{issue.cf.42}}` | Survives renaming the field |
| By name | `{{issue.cf.vertragsnummer}}` | Lowercased, every run of non-word characters becomes `_` |

Redmine's own field visibility applies on top of the opt-in: if the replying
agent is not allowed to see the field, the macro renders empty. That keeps an
internal field from leaking into a customer mail through a shared template.

Default subject template: `Re: [#{{issue.id}}] {{issue.subject}}`

Anything that cannot be resolved — an unknown macro, a field that is not
enabled, an empty value — renders as an empty string; a template never fails
because of a macro.

---

## Notes

- **Avoid duplicate emails**: If the autoresponder is active, enable
  *Suppress Redmine notifications* on the mailbox, otherwise the customer
  may also receive the standard Redmine notification mail.
- **Target folder**: Processed mails are moved to the configured folder
  (default: `Verarbeitet`; must exist in the mailbox). Without a target
  folder, mails stay in the inbox and would be reprocessed.
- **Client secret**: Stored in the Redmine database (table `settings`).
  Secure DB access accordingly; rotation via the plugin settings.
- **MIME send (Graph)**: The `sendMail` endpoint expects the call with
  `Content-Type: text/plain` and a Base64-encoded MIME string in the body.
  This is necessary because Exchange Online transforms the HTML body during
  JSON-based sending and in doing so decouples CID inline references from
  their attachments.

---

## Running the Tests

The plugin ships with Minitest unit tests under `test/unit/`. They run inside
the Redmine test environment and require the plugin to be installed and all
migrations to have been executed.

### Prerequisites

The tests must be executed from the **Redmine application root** (not the
plugin directory). The test database must exist and be migrated:

```bash
bundle exec rake db:create RAILS_ENV=test
bundle exec rake db:migrate RAILS_ENV=test
bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=test
```

> **Alongside RedmineUP plugins, `rake db:create` fails**: it boots Rails, and
> `redmine_contacts` calls `table_exists?` while loading its models — against the database
> that does not exist yet. Create the database with your database client first, then run
> only the two `migrate` tasks. In the deploy repo this is already wired up as a compose
> service: `docker-compose --profile test run --build --rm redmine-test`.

### Run all plugin tests

```bash
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test
```

### Run a single test file

```bash
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/helpdesk_rule_test.rb
```

### Run all unit test files in the plugin

```bash
bundle exec ruby -Itest \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_rule_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/mail_processor_filter_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/template_renderer_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_message_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_contact_test.rb \
  plugins/redmine_expert_helpdesk/test/unit/helpdesk_project_setting_test.rb
```

### When to run tests

- Before and after every code change to the plugin.
- After updating Redmine to a new version.
- After running `bundle update` to catch gem compatibility issues.
- In CI/CD, as a step after `redmine:plugins:migrate`.

### Container workflow

Because this project never uses `docker exec`, the tests are run by building
a dedicated test image. Add a `docker-compose.test.yml` (or a `test` service
to the existing compose file) that sets `RAILS_ENV=test` and overrides the
entrypoint to run the test rake task:

```yaml
# docker-compose.test.yml (example)
services:
  redmine-test:
    build:
      context: .
      dockerfile: Dockerfile.dev
    environment:
      RAILS_ENV: test
      REDMINE_PLUGINS_MIGRATE: "1"
    command: >
      bash -c "bundle exec rake db:migrate &&
               bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk &&
               bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk"
    depends_on:
      - db
```

```bash
docker compose -f docker-compose.test.yml run --rm redmine-test
```

---

## License

Copyright (C) 2026 Dennis Buehring

This program is free software; you can redistribute it and/or modify it under the terms of the
**GNU General Public License, version 2 or (at your option) any later version** — the same license
Redmine itself uses. See [`LICENSE`](LICENSE) for the full text.

This plugin is loaded into the Redmine process and patches Redmine core classes, so it is a
derivative work of Redmine and is distributed under GPL-compatible terms accordingly.

This program is distributed in the hope that it will be useful, but **WITHOUT ANY WARRANTY**;
without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

## Third-party components

The plugin bundles the following components under their own licenses. Their license banners are
kept intact in the shipped files.

| Component | Version | License | Path |
|-----------|---------|---------|------|
| [Chart.js](https://www.chartjs.org) | 4.4.6 | MIT | `assets/javascripts/chart.umd.min.js` |
| [chartjs-plugin-datalabels](https://chartjs-plugin-datalabels.netlify.app) | 2.2.0 | MIT | `assets/javascripts/chartjs-plugin-datalabels.min.js` |

Both are served locally from the plugin's assets — no CDN request is made at runtime. They are only
loaded on the SLA statistics and AI statistics pages.

No additional Ruby gems are required (Ruby standard library only).
