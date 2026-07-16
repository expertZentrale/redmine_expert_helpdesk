> English version · [Deutsche Version](README.de.md)

# Redmine expert Helpdesk

Email-to-ticket plugin for Redmine with Microsoft 365 integration via the
Microsoft Graph API (OAuth 2.0 Client Credentials Flow, app-only).

## Features

- **Email to ticket**: Mails from O365 mailboxes are created as tickets;
  replies are matched to existing tickets via `In-Reply-To` / `[#id]` subject
  patterns (uses Redmine's standard `MailHandler`, including attachments).
- **Per-project mailboxes**: Each project configures its mailboxes under the
  *Helpdesk* tab in project settings (source/target folder, defaults for
  tracker/priority/status, handling of unknown senders).
- **Central app registration**: Tenant ID, Client ID and Client Secret are
  configured once under *Administration → Plugins → Redmine Expert Helpdesk*.
- **Autoresponder**: Configurable confirmation email for new tickets.
- **Customer replies**: Reply to the customer directly from the ticket page,
  with header/footer templates; sent via MIME-based Graph API endpoint from
  the project mailbox (lands in its "Sent Items"). Supports inline images
  (CID method), regular attachments and multiple recipients in CC/BCC.
- **Address field autocomplete**: Typing in To/CC/BCC fields suggests matching
  project contacts (from 2 characters, dropdown with keyboard and mouse
  navigation, comma-separated multi-value). Display names containing commas
  are automatically quoted per RFC 2822.
- **Contacts**: Senders are automatically saved as contacts; customer list in
  the project (paginated, configurable entries per page), customer info panel
  with previous tickets on the ticket page.
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

## Email Processing

### Flow per mailbox fetch

```
Graph API (source folder)
        │
        ▼
  Black-/whitelist check ──── rejected ──▶ move to target folder
        │
        ▼
  Ignore rules ──────────── matches ────▶ move to target folder
        │
        ▼
  Download MIME
        │
        ▼
  Redmine MailHandler ──── rejected ───▶ move to target folder
    (create ticket or         (e.g. own address)
     append journal)
        │
        ├─ new ticket:  apply rules, link contact, autoresponder
        └─ reply:       link contact, add EML link to journal comment
        │
        ▼
  Create HelpdeskMessage (direction=in, EML attachment)
        │
        ▼
  Move to target folder, mark as read
```

### Matching email replies to existing tickets

Matching is handled entirely by **Redmine's own `MailHandler`** — the plugin
only provides the raw MIME data and evaluates the result.

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
reply is sent as a complete MIME message via the Graph API endpoint
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

**Transport choice**: Each mailbox can be configured to use `graph`
(Graph API, default) or `smtp` (Redmine SMTP). With SMTP, inline images are
embedded as Base64 data URIs in the HTML body.

Stored recipient addresses are shown as badges in the journal headers after
page load (client-side, by comparing `HelpdeskMessage.sent_at` with
`Journal.created_on`, tolerance 30 seconds).

**Automatic field update after sending**: Optionally, a target status and
automatic assignment to the sender can be configured in the project settings
(*Helpdesk → Reply settings*). Both are applied after a successful send,
before the ticket form is submitted.

## Contacts / Customer List

Senders are automatically saved as `HelpdeskContact` records on the first
mailbox fetch and assigned to the project.

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

1. **Button**: *Project settings → Helpdesk → "Fetch mails now"*
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

Under *Administration → Plugins → Redmine Expert Helpdesk*:

| Setting | Description |
|---------|-------------|
| Tenant ID | Azure directory ID (GUID) |
| Client ID | App registration ID (GUID) |
| Client Secret | App registration secret |
| API Key (mail fetch) | Secures the global fetch endpoint |
| API Key (SLA check) | Secures the `helpdesk/sla_check` endpoint |
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

```bash
# List helpdesk tickets of project 42
curl -H "X-Redmine-API-Key: $KEY" \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"

# Create a ticket and assign a customer by email
curl -H "X-Redmine-API-Key: $KEY" -H "Content-Type: application/json" \
     -d '{"helpdesk_ticket":{"subject":"Printer down","tracker_id":1,"contact_email":"jane@acme.example"}}' \
     "https://redmine.example.com/projects/42/helpdesk/tickets.json"
```

## Azure App Registration (one-time setup)

The following steps can be performed manually via the Azure Portal, via
PowerShell (Microsoft Graph PowerShell SDK + Exchange Online PowerShell) or
via Terraform (provider `hashicorp/azuread`).

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
#     Option A: all mailboxes whose address ends with @helpdesk.expert.de
New-ManagementScope `
  -Name "Redmine-Helpdesk-Mailboxes" `
  -RecipientRestrictionFilter "PrimarySmtpAddress -like '*@helpdesk.expert.de'"
#
#     Option B: members of a mail-enabled security group
#     $dn = (Get-Group "helpdesk-mailboxes@expert.de").DistinguishedName
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
  -Resource helpdesk@expert.de | Format-Table
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

In Redmine under *Administration → Plugins → Redmine Expert Helpdesk* enter
Tenant ID, Client ID and Client Secret.

---

## Installation

The plugin lives in `plugins/redmine_expert_helpdesk` and is copied into the
image via the Dockerfile. Migrations run automatically on container start when
`REDMINE_PLUGINS_MIGRATE=1` is set, otherwise manually:

```bash
bundle exec rake redmine:plugins:migrate RAILS_ENV=production
```

Then enable the **Helpdesk** module in the project and assign permissions to
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

| Macro (dot notation) | Short form | Meaning |
|----------------------|------------|---------|
| `{{issue.id}}` | `{{ticket_id}}` | Ticket number |
| `{{issue.subject}}` | `{{ticket_subject}}` | Ticket title |
| `{{issue.url}}` | `{{ticket_url}}` | Link to the ticket |
| `{{contact.name}}` | `{{contact_name}}` | Customer name |
| `{{contact.email}}` | `{{contact_email}}` | Customer email |
| `{{user.name}}` | `{{user_name}}` | Name of the replying user |
| `{{project.name}}` | `{{project_name}}` | Project name |

Default subject template: `Re: [#{{issue.id}}] {{issue.subject}}`

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
