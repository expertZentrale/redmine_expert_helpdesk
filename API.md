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

Tickets additionally require the **Helpdesk module** to be enabled on the project
(otherwise **403**). Contacts addressed globally by id (`/helpdesk/contacts/:id`)
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

Only **contacts**, **tickets** and **project settings** are exposed via this REST API
(see the sections below). The following helpdesk resources are **not** yet available —
they can currently only be managed through the Redmine UI. Plan automations
accordingly; these may be added later.

| Resource | Model / area | Today | Notes |
|----------|--------------|-------|-------|
| **Mailboxes** | `HelpdeskMailbox` | UI only | Per-project O365 mailbox config (folders, filters, autoresponder, reply transport). No REST create/read/update/delete. |
| **Rules** | `HelpdeskRule` | UI only | Per-mailbox automation rules (subject/sender → set field / ignore). |
| **Messages** (standalone) | `HelpdeskMessage` | Embedded only | The message log is available **inside a ticket** via `GET /helpdesk/tickets/:id.json?include=messages`. There is **no** standalone messages collection, single-message endpoint, or `.eml` download. |
| **Agent replies** | `helpdesk_replies` | UI only | Sending a reply e-mail to the customer (MIME / Graph / SMTP) is not exposed. |
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
      "mailbox": { "id": 5, "address": "support@example.com" },
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
| `reply_assign_to_sender` | boolean | |
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
`mailbox {id,address}` (if any), `sla` (if applicable), `messages` (show +
`include=messages`).

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
