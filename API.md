# Redmine Expert Helpdesk — REST API

The plugin exposes a REST API (JSON **and** XML) for automations, following
Redmine core's conventions. This document covers every endpoint, all parameters,
and example requests/responses for each case.

- [Getting started](#getting-started)
  - [Enabling the API](#enabling-the-api)
  - [Authentication](#authentication)
  - [Response format (JSON / XML)](#response-format-json--xml)
  - [Pagination](#pagination)
  - [Permissions](#permissions)
  - [Error responses](#error-responses)
- [Not yet available via REST](#not-yet-available-via-rest)
- [Contacts](#contacts)
- [Tickets](#tickets)
- [Project settings](#project-settings)
- [Mailboxes](#mailboxes)
- [Data reference](#data-reference)

---

## Getting started

### Enabling the API

The API only works when Redmine's REST web service is enabled:
*Administration → Settings → API → **Enable REST web service***.
When it is disabled, all requests are rejected with **401 Unauthorized**.

### Authentication

Same mechanisms as Redmine core (in order of preference):

| Method | How |
|--------|-----|
| API key header | `X-Redmine-API-Key: <key>` |
| API key query param | `?key=<key>` |
| HTTP Basic auth | `-u <login>:<password>` |
| HTTP Basic with key | `-u <key>:x` |

Your personal API key is shown under *My account* (right column) once the API is
enabled. The acting user's role permissions determine what each request may do.

### Response format (JSON / XML)

Choose the format with the path extension:

- `…​.json` → `application/json`
- `…​.xml` → `application/xml`

For request **bodies**, send JSON with `Content-Type: application/json` (or XML with
`Content-Type: application/xml`). The examples below use JSON bodies.

### Pagination

List endpoints accept:

| Param | Default | Notes |
|-------|---------|-------|
| `offset` | `0` | Number of records to skip |
| `limit` | `25` | Page size (Redmine caps it at `100`) |

List responses include the paging metadata `total_count`, `offset`, `limit`
alongside the array.

### Permissions

| Resource | Read (index/show) | Write (create/update/delete) |
|----------|-------------------|------------------------------|
| Contacts | `view_helpdesk_info` | `manage_helpdesk_contacts` |
| Tickets | `view_issues` | `add_issues` / `edit_issues` / `delete_issues` |
| Project settings | `view_helpdesk_info` or `manage_helpdesk` | `manage_helpdesk` |
| Mailboxes | `manage_helpdesk` | `manage_helpdesk` |

**Mailboxes require `manage_helpdesk` for reading, too** — the configuration exposes
mail hosts, usernames, OAuth client/tenant ids and the last connection error, which
`view_helpdesk_info` (granted to everyone who may see customer data) has no business
seeing.

Tickets, project settings and mailboxes additionally require the **Helpdesk module**
to be enabled on the project (otherwise **403**). Contacts addressed globally by id (`/helpdesk/contacts/:id`)
without a project resolve their project from the contact record; a contact with no
project requires an admin.

### Error responses

| Status | When |
|--------|------|
| `200 OK` | Successful read (index / show) |
| `201 Created` | Successful create |
| `204 No Content` | Successful update / delete (empty body) |
| `401 Unauthorized` | API disabled, missing/invalid key |
| `403 Forbidden` | Authenticated but lacking the required permission (or module off) |
| `404 Not Found` | Resource id does not exist / not visible |
| `422 Unprocessable Entity` | Validation failed |

Validation errors (422) use Redmine's standard envelope:

```json
{ "errors": ["Email cannot be blank"] }
```

```xml
<?xml version="1.0" encoding="UTF-8"?>
<errors type="array">
  <error>Email cannot be blank</error>
</errors>
```

---

## Not yet available via REST

Only **contacts**, **tickets**, **project settings** and **mailboxes** are exposed via
this REST API (see the sections below). The following helpdesk resources are **not** yet
available — they can currently only be managed through the Redmine UI. Plan automations
accordingly; these may be added later.

| Resource | Model / area | Today | Notes |
|----------|--------------|-------|-------|
| **Rules** | `HelpdeskRule` | UI only | Per-mailbox automation rules (subject/sender → set field / ignore). |
| **OAuth consent** | `/helpdesk/oauth/authorize` | UI only | The interactive `authorization_code` consent (and the refresh token it produces) cannot be driven through the API — an identity provider needs a browser. Mailboxes using that grant must be connected once in the UI. |
| **Messages** (standalone) | `HelpdeskMessage` | Embedded only | The message log is available **inside a ticket** via `GET /helpdesk/tickets/:id.json?include=messages`. There is **no** standalone messages collection, single-message endpoint, or `.eml` download. |
| **Agent replies** | `helpdesk_replies` | UI only | Sending a reply e-mail to the customer (via the mailbox's own backend, Graph, or Redmine's global SMTP) is not exposed. |
| **Initial outbound mail** | `helpdesk_init` | Partial | Assigning a customer to a ticket **is** possible via the ticket API (`contact_email` / `contact_id`), but **sending** the initial e-mail to the customer is not. |
| **SLA statistics** | `helpdesk_sla_statistics` | UI only | The per-project statistics/aggregations have no REST endpoint. |
| **SLA priority overrides** (standalone) | `HelpdeskSlaPriority` | Via settings | Read/written **within** [Project settings](#project-settings) (`sla_priorities`); there is no dedicated `/helpdesk/sla_priorities` resource. |
| **Phishing URL mirror** | `HelpdeskPhishingUrl` | UI/cron only | Admin/global PhishTank + Phishing.Database mirror; not exposed. |
| **Legacy import / attachment repair** | `helpdesk_legacy_import` | UI only | One-off admin maintenance actions. |

### Separate machine endpoints (not part of this REST API)

Two automation endpoints exist but use their **own** static API key (`?key=…`,
configured in the plugin settings), **not** `X-Redmine-API-Key`, and are not
permission-scoped like the resources above:

- **Trigger mail fetch** — `GET`/`POST /helpdesk/fetch_all?key=<fetch_api_key>`
- **Trigger SLA check** — `GET`/`POST /helpdesk/sla_check?key=<sla_api_key>`

See the plugin `README` for these.

---

## Contacts

Customers/contacts are **project-scoped** (the same email may exist once per
project). `email` is required and is set only on **create** (immutable afterwards);
`name`, `company`, `phone`, `notes` are writable.

### Endpoints

| Method | Path | Action |
|--------|------|--------|
| GET | `/projects/:project_id/helpdesk/contacts.{json,xml}` | List |
| POST | `/projects/:project_id/helpdesk/contacts.{json,xml}` | Create |
| GET | `/helpdesk/contacts/:id.{json,xml}` | Show |
| PUT | `/helpdesk/contacts/:id.{json,xml}` | Update |
| DELETE | `/helpdesk/contacts/:id.{json,xml}` | Delete |

### List contacts

`GET /projects/:project_id/helpdesk/contacts.{json,xml}`

Query parameters:

| Param | Type | Description |
|-------|------|-------------|
| `email` | string | Exact match (case-insensitive). Takes precedence over `search`. |
| `search` | string | Substring match over name, email, company (case-insensitive). |
| `offset` | integer | Paging offset (default `0`). |
| `limit` | integer | Page size (default `25`, max `100`). |

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/projects/42/helpdesk/contacts.json?search=acme&limit=50"
```

Response `200`:

```json
{
  "helpdesk_contacts": [
    {
      "id": 7,
      "email": "jane@acme.example",
      "name": "Jane Doe",
      "company": "Acme",
      "phone": "+49 30 1234567",
      "notes": "VIP",
      "project": { "id": 42 },
      "created_on": "2026-07-01T10:00:00Z",
      "updated_on": "2026-07-08T12:30:00Z"
    }
  ],
  "total_count": 1,
  "offset": 0,
  "limit": 50
}
```

### Show a contact

`GET /helpdesk/contacts/:id.{json,xml}`

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/helpdesk/contacts/7.xml"
```

Response `200` (XML):

```xml
<?xml version="1.0" encoding="UTF-8"?>
<helpdesk_contact>
  <id>7</id>
  <email>jane@acme.example</email>
  <name>Jane Doe</name>
  <company>Acme</company>
  <phone>+49 30 1234567</phone>
  <notes>VIP</notes>
  <project id="42"/>
  <created_on>2026-07-01T10:00:00Z</created_on>
  <updated_on>2026-07-08T12:30:00Z</updated_on>
</helpdesk_contact>
```

### Create a contact

`POST /projects/:project_id/helpdesk/contacts.{json,xml}`

Body — object key `helpdesk_contact`:

| Field | Type | Required | Notes |
|-------|------|----------|-------|
| `email` | string | **yes** | Lower-cased & trimmed; unique per project. |
| `name` | string | no | |
| `company` | string | no | |
| `phone` | string | no | |
| `notes` | string | no | |

```bash
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_contact":{"email":"jane@acme.example","name":"Jane Doe","company":"Acme","phone":"+49 30 1234567"}}' \
     "https://redmine.example.com/projects/42/helpdesk/contacts.json"
```

Responses: `201 Created` with the contact (same shape as *Show*); `422` if `email`
is blank or already exists in that project.

### Update a contact

`PUT /helpdesk/contacts/:id.{json,xml}`

Body — `helpdesk_contact` with any of `name`, `company`, `phone`, `notes`
(`email` is **ignored** on update).

```bash
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_contact":{"company":"Acme GmbH","notes":"Renewed 2026"}}' \
     "https://redmine.example.com/helpdesk/contacts/7.json"
```

Response: `204 No Content` (empty body); `422` on validation error.

### Delete a contact

`DELETE /helpdesk/contacts/:id.{json,xml}`

```bash
curl -X DELETE -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/helpdesk/contacts/7.json"
```

Response: `204 No Content`.

---

## Tickets

A **helpdesk ticket** is a Redmine issue enriched with helpdesk data. Issue fields
are persisted by the core `Issue` model (so all issue rules/workflows/permissions
apply); the API additionally embeds the assigned `contact`, originating `mailbox`,
live `sla` state, and the `messages` log. **List** only returns issues that already
have a helpdesk record (i.e. real helpdesk tickets) in the project.

### Endpoints

| Method | Path | Action |
|--------|------|--------|
| GET | `/projects/:project_id/helpdesk/tickets.{json,xml}` | List |
| POST | `/projects/:project_id/helpdesk/tickets.{json,xml}` | Create |
| GET | `/helpdesk/tickets/:id.{json,xml}` | Show |
| PUT | `/helpdesk/tickets/:id.{json,xml}` | Update |
| DELETE | `/helpdesk/tickets/:id.{json,xml}` | Delete |

### List tickets

`GET /projects/:project_id/helpdesk/tickets.{json,xml}`

Query parameters: `offset`, `limit` (see [Pagination](#pagination)). Ordered newest
first. The list representation omits `description` and `messages` for brevity.

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json?limit=20"
```

Response `200`:

```json
{
  "helpdesk_tickets": [
    {
      "id": 1024,
      "project": { "id": 42, "name": "Support" },
      "tracker": { "id": 1, "name": "Incident" },
      "status": { "id": 2, "name": "In Progress" },
      "priority": { "id": 4, "name": "High" },
      "subject": "Printer down",
      "author": { "id": 3, "name": "Agent Smith" },
      "assigned_to": { "id": 3, "name": "Agent Smith" },
      "done_ratio": 0,
      "created_on": "2026-07-08T09:26:00Z",
      "updated_on": "2026-07-08T09:40:00Z",
      "closed_on": null,
      "contact": {
        "id": 7, "email": "jane@acme.example", "name": "Jane Doe",
        "company": "Acme", "phone": "+49 30 1234567"
      },
      "mailbox": { "id": 5, "address": "support@example.com", "provider": "imap" },
      "sla": {
        "reaction": { "status": "warning", "minutes": 48, "target": 60,
                      "due_at": "2026-07-08T10:26:00Z" },
        "solution": { "status": "running", "minutes": 48, "target": 480,
                      "due_at": "2026-07-08T17:00:00Z" }
      }
    }
  ],
  "total_count": 1,
  "offset": 0,
  "limit": 20
}
```

`sla` (and either clock within it) is omitted when SLA is not enabled/applicable.
`contact` / `mailbox` are omitted when the ticket has none. See
[SLA status values](#sla-status-values).

### Show a ticket

`GET /helpdesk/tickets/:id.{json,xml}`

Query parameters:

| Param | Description |
|-------|-------------|
| `include` | Comma-separated extras. Currently: `messages` — include the message log. |

The show representation adds `description` and (with `include=messages`) a
`messages` array.

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/helpdesk/tickets/1024.json?include=messages"
```

Response `200` (excerpt — the `messages` part):

```json
{
  "helpdesk_ticket": {
    "id": 1024,
    "subject": "Printer down",
    "description": "The 3rd-floor printer is offline.",
    "contact": { "id": 7, "email": "jane@acme.example", "name": "Jane Doe" },
    "sla": { "reaction": { "status": "met", "minutes": 12, "target": 60 } },
    "messages": [
      {
        "id": 900,
        "direction": "in",
        "subject": "Printer down",
        "sent_at": "2026-07-08T09:26:00Z",
        "recipient_to": "support@example.com",
        "recipient_cc": null,
        "recipient_bcc": null,
        "contact": { "id": 7 },
        "mailbox": { "id": 5 },
        "created_on": "2026-07-08T09:26:05Z"
      }
    ]
  }
}
```

`direction` is one of `in` (incoming customer mail), `out` (agent reply), `init`
(initial/creation contact).

### Create a ticket

`POST /projects/:project_id/helpdesk/tickets.{json,xml}`

Body — object key `helpdesk_ticket`. Issue fields are the standard Redmine issue
attributes (subject required; the rest follow the project's trackers/workflow):

| Field | Type | Notes |
|-------|------|-------|
| `subject` | string | Required. |
| `description` | string | |
| `tracker_id` | integer | Defaults to the project's first tracker if omitted. |
| `status_id` | integer | Defaults to the tracker's default status. |
| `priority_id` | integer | Defaults to the default priority. |
| `assigned_to_id` | integer | |
| `category_id` | integer | |
| `fixed_version_id` | integer | |
| `start_date`, `due_date` | date | |
| `custom_field_values` | object | `{ "1": "value", … }` |

Helpdesk-specific fields (optional — assign a customer at creation):

| Field | Type | Notes |
|-------|------|-------|
| `contact_id` | integer | Link an existing contact of this project. |
| `contact_email` | string | Link (or create) a contact by email in this project. |
| `contact_name` | string | Name used only when creating via `contact_email`. |

When a contact is assigned, the ticket's helpdesk info is set and SLA deadlines are
(re)computed.

```bash
# Minimal: subject + tracker, link a customer by email
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"Printer down","tracker_id":1,"contact_email":"jane@acme.example","contact_name":"Jane Doe"}}' \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"

# Full: priority, assignee, description, existing contact id
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"VPN broken","description":"Cannot connect","tracker_id":1,"priority_id":4,"assigned_to_id":3,"contact_id":7}}' \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"
```

Responses: `201 Created` with the full ticket (as *Show*); `422` on issue
validation errors (e.g. missing subject, invalid status transition); `403` without
`add_issues` or if the Helpdesk module is off.

### Update a ticket

`PUT /helpdesk/tickets/:id.{json,xml}`

Body — `helpdesk_ticket` with any writable issue field above, plus:

| Field | Type | Notes |
|-------|------|-------|
| `notes` | string | Added as a journal note (like the core issues API). |
| `contact_id` / `contact_email` / `contact_name` | | Reassign / set the customer. |

```bash
# Change status + priority and add a note
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"status_id":3,"priority_id":5,"notes":"Escalated to L2"}}' \
     "https://redmine.example.com/helpdesk/tickets/1024.json"

# Reassign the customer
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"contact_email":"bob@acme.example"}}' \
     "https://redmine.example.com/helpdesk/tickets/1024.json"
```

Response: `204 No Content`; `422` on validation error; `403` without `edit_issues`.

### Delete a ticket

`DELETE /helpdesk/tickets/:id.{json,xml}`

Deletes the underlying issue (requires `delete_issues`) and removes the ticket's
helpdesk info; helpdesk messages are detached (their `issue_id` is cleared).

```bash
curl -X DELETE -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/helpdesk/tickets/1024.json"
```

Response: `204 No Content`.

---

## Project settings

The per-project helpdesk configuration (reply defaults, phishing, SLA settings and
per-priority SLA overrides). It is a **singleton per project** — there is no create
or delete, only show and update.

| Method | Path | Action |
|--------|------|--------|
| GET | `/projects/:project_id/helpdesk/settings.{json,xml}` | Show |
| PUT | `/projects/:project_id/helpdesk/settings.{json,xml}` | Update (partial) |

Read requires `view_helpdesk_info` (or `manage_helpdesk`); write requires
`manage_helpdesk`. The Helpdesk module must be enabled on the project.

### Show settings

`GET /projects/:project_id/helpdesk/settings.{json,xml}`

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/projects/42/helpdesk/settings.json"
```

Response `200`:

```json
{
  "helpdesk_project_setting": {
    "project": { "id": 42 },
    "send_reply_by_default": true,
    "reply_subject_template": "Re: [#{{issue.id}}] {{issue.subject}}",
    "reply_status_id": 2,
    "reply_assign_to_sender": false,
    "default_assigned_to_id": 7,
    "phishing_check_enabled": true,
    "phishing_action": "neutralize",
    "sla_enabled": true,
    "sla_enabled_at": "2026-07-01T00:00:00Z",
    "sla_reaction_minutes": 60,
    "sla_solution_minutes": 480,
    "sla_work_days": "1,2,3,4,5",
    "sla_work_start": "08:00",
    "sla_work_end": "17:00",
    "sla_notify_enabled": true,
    "sla_notify_email": "sla@example.com",
    "sla_notify_user_id": null,
    "ai_summary_enabled": false,
    "ai_summary_scope": "initial",
    "ai_prompt_mode": "inherit",
    "ai_prompt": null,
    "ai_attach_metadata": true,
    "ai_attach_text": false,
    "ai_attach_images": false,
    "ai_include_journal": false,
    "ai_include_private_notes": false,
    "info_request_mode": "off",
    "info_request_min_chars": 200,
    "info_request_min_words": 20,
    "info_request_require_attachment": false,
    "info_request_min_attachment_kb": 15,
    "info_request_keywords": null,
    "info_request_threshold": 1,
    "info_request_ai_prompt_mode": "inherit",
    "info_request_ai_prompt": null,
    "info_request_subject": null,
    "info_request_body": null,
    "info_request_note_visibility": "public",
    "info_request_status_id": null,
    "kb_ingest_mode": "off",
    "kb_proposal_display": "off",
    "sla_priorities": [
      { "priority_id": 5, "priority_name": "Urgent", "reaction_minutes": 15, "solution_minutes": 120 }
    ]
  }
}
```

### Update settings

`PUT /projects/:project_id/helpdesk/settings.{json,xml}`

A **partial** update — only the keys you send are changed. Body key
`helpdesk_project_setting`:

| Field | Type | Notes |
|-------|------|-------|
| `send_reply_by_default` | boolean | |
| `reply_subject_template` | string | |
| `reply_status_id` | integer \| null | Default status applied after a reply. |
| `reply_assign_to_sender` | boolean | Assigns the replying agent, but only while the ticket is still unassigned. |
| `default_assigned_to_id` | integer \| null | Principal (user **or** group) that new tickets from incoming mail are assigned to. `null` = do not assign. Not validated on write; a principal that is not assignable in the project is skipped when the ticket is created. |
| `phishing_check_enabled` | boolean | |
| `phishing_action` | string | `neutralize` or `quarantine`. |
| `sla_enabled` | boolean | Turning it on stamps `sla_enabled_at` (SLA then applies to tickets created from that moment). |
| `sla_reaction_minutes` | integer \| null | Target business minutes. |
| `sla_solution_minutes` | integer \| null | Target business minutes. |
| `sla_work_days` | array of int **or** CSV string | ISO weekdays `1`=Mon … `7`=Sun (e.g. `[1,2,3,4,5]` or `"1,2,3,4,5"`). |
| `sla_work_start` / `sla_work_end` | string `HH:MM` | Business hours window. |
| `sla_notify_enabled` | boolean | |
| `sla_notify_email` | string \| null | |
| `sla_notify_user_id` | integer \| null | |
| `ai_summary_enabled` | boolean | Opt-in AI summary of incoming mail (off by default). |
| `ai_summary_scope` | string | `initial` or `initial_and_replies`. |
| `ai_prompt_mode` | string | `inherit`, `extend` or `override` — how the project prompt combines with the central default prompt. |
| `ai_prompt` | string \| null | Project prompt. |
| `ai_attach_metadata` / `ai_attach_text` / `ai_attach_images` | boolean | Which parts of the attachments are fed to the model. |
| `ai_include_journal` | boolean | Send the whole ticket history instead of just the mail body. |
| `ai_include_private_notes` | boolean | Include private journal notes. |
| `info_request_mode` | string | `off`, `heuristic` or `ai` — completeness check of the first mail of a new ticket (off by default). |
| `info_request_min_chars` / `info_request_min_words` | integer \| null | Rule mode: minimum body length. `0` disables the individual rule. |
| `info_request_require_attachment` | boolean | Rule mode: treat a mail with no attachment as incomplete. |
| `info_request_min_attachment_kb` | integer \| null | Images below this size do not count as a screenshot/photo (signature logos, tracking pixels). Images only; `0` disables the floor. |
| `info_request_keywords` | string \| null | Rule mode: expected terms, one per line (or comma-separated). Empty disables the rule. |
| `info_request_threshold` | integer \| null | How many rules must fail before the customer is asked. Minimum 1. |
| `info_request_ai_prompt_mode` | string | `inherit`, `extend` or `override`, as for `ai_prompt_mode`. |
| `info_request_ai_prompt` | string \| null | Project prompt for the AI check. |
| `info_request_subject` / `info_request_body` | string \| null | Override the central follow-up templates. `{{missing_info}}` inserts the list of missing details. |
| `info_request_note_visibility` | string | `public` or `private` — whether the journal note recording the follow-up is visible to the customer. |
| `info_request_status_id` | integer \| null | Status set after a follow-up went out; `null` leaves the status untouched. |
| `kb_ingest_mode` | string | `off`, `auto` or `manual` — whether resolved tickets feed the knowledge base. |
| `kb_proposal_display` | string | `off`, `summary`, `sidebar` or `both`. |

Per-priority SLA overrides — top-level `sla_priorities` array of
`{ priority_id, reaction_minutes, solution_minutes }`. An entry with **both**
minutes null/empty **removes** that override; otherwise it is created/updated.

```bash
# Enable SLA with targets and a Mon–Fri 08–17 window, plus an override for priority 5
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{
           "helpdesk_project_setting": {
             "sla_enabled": true,
             "sla_reaction_minutes": 60,
             "sla_solution_minutes": 480,
             "sla_work_days": [1,2,3,4,5],
             "sla_work_start": "08:00",
             "sla_work_end": "17:00"
           },
           "sla_priorities": [
             { "priority_id": 5, "reaction_minutes": 15, "solution_minutes": 120 }
           ]
         }' \
     "https://redmine.example.com/projects/42/helpdesk/settings.json"
```

Response: `200 OK` with the full settings (as *Show*); `422` on validation error
(e.g. bad `phishing_action`, non-`HH:MM` times, non-positive minutes). After a
successful update the open tickets' SLA deadlines are recomputed.

---

## Mailboxes

A **mailbox** is the per-project mail backend: which server the helpdesk fetches from,
how it authenticates, which folders it uses, and how replies leave the system. Each
mailbox picks its backend with `provider`:

| `provider` | Backend |
|------------|---------|
| `graph` | Microsoft 365 via the Graph API and the central app registration (plugin settings). |
| `imap` | Generic IMAP for receiving and SMTP for sending — any provider, with password or OAuth2 auth. |

Reading **and** writing require `manage_helpdesk` plus the Helpdesk module on the project
(see [Permissions](#permissions)).

### Secrets are write-only

`mail_password`, `oauth_client_secret` and `oauth_sa_key` can be **set** but are **never
returned**. Responses carry `mail_password_set`, `oauth_client_secret_set`,
`oauth_sa_key_set` and `oauth_refresh_token_set` booleans instead. Write semantics:

| You send | Effect |
|----------|--------|
| the key omitted, or an empty string | the stored secret is **kept** |
| any other value | the secret is **replaced** |
| `"-"` | the secret is **cleared** |

`oauth_refresh_token` cannot be set through the API at all — it is produced by the
interactive OAuth consent in the UI (`authorization_code` grant). Use
`oauth_connected` to check whether that consent is still outstanding.

### Endpoints

| Method | Path | Purpose |
|--------|------|---------|
| `GET` | `/projects/:project_id/helpdesk/mailboxes.:format` | List the project's mailboxes |
| `POST` | `/projects/:project_id/helpdesk/mailboxes.:format` | Create a mailbox |
| `GET` | `/helpdesk/mailboxes/:id.:format` | Show one mailbox |
| `PUT` | `/helpdesk/mailboxes/:id.:format` | Update a mailbox (partial) |
| `DELETE` | `/helpdesk/mailboxes/:id.:format` | Delete a mailbox |
| `POST` | `/helpdesk/mailboxes/:id/test_connection.:format` | Probe the configured backend |

### List mailboxes

`GET /projects/:project_id/helpdesk/mailboxes.:format`

| Parameter | Type | Description |
|-----------|------|-------------|
| `enabled` | boolean | Only enabled (`1`) or only disabled (`0`) mailboxes. |
| `provider` | string | `graph` or `imap`. |
| `offset`, `limit` | integer | [Pagination](#pagination). |

```bash
curl -H "X-Redmine-API-Key: $KEY" \
     "$URL/projects/1/helpdesk/mailboxes.json?provider=imap"
```

```json
{
  "helpdesk_mailboxes": [ { "id": 5, "mailbox_address": "support@example.com", "provider": "imap" } ],
  "total_count": 1,
  "offset": 0,
  "limit": 25
}
```

(Each entry is a full [mailbox object](#mailbox-object); shortened here.)

### Show a mailbox

`GET /helpdesk/mailboxes/:id.:format` → **200** with a `helpdesk_mailbox` object,
**404** if it does not exist, **403** without `manage_helpdesk`.

### Create a mailbox

`POST /projects/:project_id/helpdesk/mailboxes.:format` → **201** with the created
object, **422** on validation errors.

`project_id` comes from the route and is ignored in the payload — a mailbox cannot be
created in a different project than the one addressed.

```bash
# Generic IMAP/SMTP mailbox with password auth
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_mailbox":{
           "mailbox_address":"support@example.com",
           "provider":"imap",
           "credentials_source":"mailbox",
           "auth_method":"password",
           "imap_host":"imap.example.com","imap_port":993,"imap_security":"ssl",
           "smtp_host":"smtp.example.com","smtp_port":587,"smtp_security":"starttls",
           "mail_password":"s3cret"}}' \
     "$URL/projects/1/helpdesk/mailboxes.json"

# Microsoft 365 mailbox using the central app registration
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_mailbox":{"mailbox_address":"support@example.com","provider":"graph"}}' \
     "$URL/projects/1/helpdesk/mailboxes.json"
```

Validation worth knowing: `imap_host` is required when `provider` is `imap`;
`smtp_host` is required when the mailbox sends through its own SMTP server; and
`reply_transport: "graph"` is rejected unless the mailbox is actually Microsoft-hosted
(`provider: "graph"`, or `provider: "imap"` whose **effective** preset is `microsoft` — the
`oauth_preset` field only counts with `credentials_source: "mailbox"`, otherwise the plugin's
global default preset applies) and a central app registration is configured. Read
`available_reply_transports` off the mailbox to see what a given mailbox accepts.

Blank connection fields are filled from the selected `oauth_preset` and the plugin's
global defaults on save, so a minimal payload is usually enough.

### Update a mailbox

`PUT /helpdesk/mailboxes/:id.:format` → **204 No Content**, **422** on validation
errors. Partial: only the keys you send are changed.

```bash
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_mailbox":{"enabled":false,"processed_folder":"Verarbeitet"}}' \
     "$URL/helpdesk/mailboxes/5.json"

# Clear the stored password
curl -X PUT -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_mailbox":{"mail_password":"-"}}' \
     "$URL/helpdesk/mailboxes/5.json"
```

After create and update the plugin tries to create the mailbox's target folders
(`processed_folder`, `skipped_folder`, `failed_folder`) on the server, exactly as the
UI does. A failure there is logged and does not fail the request — the mailbox is saved
either way.

### Delete a mailbox

`DELETE /helpdesk/mailboxes/:id.:format` → **204 No Content**. Its rules are deleted
with it; logged messages are kept and simply lose their mailbox link.

### Test the connection

`POST /helpdesk/mailboxes/:id/test_connection.:format` probes the stored configuration
(IMAP login or Graph access) and lists the folders it found. It always works on the
**persisted** record — unlike the UI it does not accept draft form state.

```bash
curl -X POST -H "X-Redmine-API-Key: $KEY" \
     "$URL/helpdesk/mailboxes/5/test_connection.json"
```

```json
{
  "connection_test": {
    "ok": true,
    "message": "Verbindung erfolgreich",
    "folders": ["INBOX", "Verarbeitet", "Fehlgeschlagen"],
    "sent_folder": "Gesendete Elemente"
  }
}
```

Returns **422** with `"ok": false` and a `message` when the mailbox is not configured
or the backend rejected the connection. `sent_folder` is only present for IMAP mailboxes.

## Data reference

### Contact object

| Field | Type | Notes |
|-------|------|-------|
| `id` | integer | |
| `email` | string | |
| `name` | string \| null | |
| `company` | string \| null | |
| `phone` | string \| null | |
| `notes` | string \| null | |
| `project` | object `{ id }` \| absent | Absent for global (project-less) contacts. |
| `created_on` / `updated_on` | datetime (ISO 8601) | |

Embedded contact reference (inside a ticket / message) is the compact form
`{ id, email, name, company, phone }` (name = display name).

### Ticket object

Issue fields: `id`, `project {id,name}`, `tracker {id,name}`, `status {id,name}`,
`priority {id,name}`, `subject`, `description` (show only), `author {id,name}`,
`assigned_to {id,name}` (if any), `done_ratio`, `created_on`, `updated_on`,
`closed_on`. Helpdesk fields: `contact` (compact contact, if any),
`mailbox {id,address,provider}` (if any), `sla` (if applicable), `messages` (show +
`include=messages`).

### Mailbox object

Returned by the [mailbox endpoints](#mailboxes) under the root key `helpdesk_mailbox`.
Embedded ticket/message references are the compact form (`id`, `address`, `provider`)
only.

| Group | Fields |
|-------|--------|
| Identity | `id`, `project {id,name}`, `mailbox_address`, `enabled` |
| Backend | `provider` (`graph`\|`imap`), `reply_transport` (`provider`\|`graph`\|`smtp`), `outgoing_route` (resolved: `graph`\|`mailbox_smtp`\|`smtp`), `available_reply_transports` (array), `microsoft_hosted` |
| Folders | `source_folder`, `processed_folder`, `skipped_folder`, `failed_folder`, `sent_folder` |
| Ticket defaults | `default_tracker_id`, `default_priority_id`, `default_status_id`, `unknown_user_mode` (`accept`\|`create`\|`ignore`), `suppress_notifications`, `reopen_status_id`, `reopen_max_age_days` |
| Filters & replies | `allow_list`, `deny_list`, `auto_reply_filter_enabled`, `auto_reply_sender_whitelist`, `auto_reply_header_whitelist`, `autoresponder_enabled`, `autoresponder_subject`, `autoresponder_body`, `reply_header`, `reply_footer`, `footer_mode` (`inherit`\|`prepend`\|`override`) |
| Connection | `credentials_source` (`global`\|`mailbox`), `auth_method` (`oauth2`\|`password`), `imap_host`, `imap_port`, `imap_security` (`ssl`\|`starttls`\|`plain`), `imap_username`, `imap_verify_ssl`, `imap_unseen_only`, `imap_timeout`, `smtp_host`, `smtp_port`, `smtp_security`, `smtp_username`, `smtp_verify_ssl` |
| OAuth2 | `oauth_preset` (`microsoft`\|`google`\|`generic`), `oauth_grant` (`client_credentials`\|`authorization_code`\|`jwt_bearer`), `oauth_tenant_id`, `oauth_client_id`, `oauth_authorize_url`, `oauth_token_url`, `oauth_scope`, `oauth_sa_email`, `oauth_connected`, `oauth_connected_at`, `oauth_token_expires_at` |
| Secret presence | `mail_password_set`, `oauth_client_secret_set`, `oauth_sa_key_set`, `oauth_refresh_token_set` — booleans; the values themselves are never returned |
| Status | `last_fetched_at`, `last_error`, `last_error_at`, `created_on`, `updated_on` |

`outgoing_route`, `available_reply_transports`, `microsoft_hosted`, `oauth_connected`
and the `*_set` booleans are derived and read-only. Everything else in the first seven
groups is writable, plus the write-only `mail_password`, `oauth_client_secret` and
`oauth_sa_key`.

### SLA object

```
sla: {
  reaction: { status, minutes, target, due_at? },
  solution: { status, minutes, target, due_at? }
}
```

- `minutes` — business minutes elapsed (running) or consumed (finished).
- `target` — target business minutes for that clock.
- `due_at` — absolute deadline; present while the clock is still running.

#### SLA status values

| Status | Meaning |
|--------|---------|
| `met` | Finished within target |
| `breached_done` | Finished, but target was exceeded |
| `running` | Active, < 80 % of target consumed |
| `warning` | Active, ≥ 80 % of target consumed |
| `breached` | Active, target already exceeded |

For the reaction clock, "finished" means the first response was recorded — or, for
a closed ticket without a recorded response, the close time.

### Message object

`{ id, direction (in|out|init), subject, sent_at, recipient_to, recipient_cc,
recipient_bcc, contact {id}?, mailbox {id}?, created_on }`.
