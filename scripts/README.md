# Microsoft 365 setup scripts

> 🇬🇧 English version · [Deutsche Version](README.de.md)

Repo-internal tooling for the one-time Microsoft 365 / Entra ID setup the plugin needs for
Graph mailboxes (and for IMAP/SMTP mailboxes that authenticate with OAuth2). Excluded from
the release archives — these never ship to plugin users.

| Script | Purpose |
|---|---|
| `setup-azure-app.ps1` | Creates and extends the app registration, its Graph permissions, the client secret and the Exchange Online RBAC scope. Re-runnable. |
| `delete-app-registration.ps1` | Removes everything again (clean slate), asking before each destructive step. |

Both are the executable form of the *Azure App Registration* section in
[`../README.md`](../README.md), which also documents the Azure Portal, Azure CLI and Terraform
equivalents.

```powershell
# Initial setup
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com" -TestMailbox "helpdesk@example.com"

# Once the test above reports InScope: True — see "Why step 5 matters" below
./setup-azure-app.ps1 -RemoveEntraGraphPermissions

# Later: another project, another mailbox
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"
```

---

## How the permission model works

Access is governed by **two independent layers**, and the second one only means anything once
the first is gone.

**Layer 1 — Entra ID application permissions.** `Mail.ReadWrite` and `Mail.Send` are granted to
the app registration as *application* permissions (app-only, no signed-in user). They are
**tenant-wide**: an app holding them can read and send as **every mailbox in the tenant**. There
is no way to narrow them in Entra ID itself.

**Layer 2 — Exchange Online Application RBAC.** A *management scope* defines a set of mailboxes
via a recipient filter, and two *management role assignments*
(`Application Mail.ReadWrite`, `Application Mail.Send`) bind the app to that scope. This is what
actually restricts the app to the helpdesk mailboxes. It replaces the deprecated
`New-ApplicationAccessPolicy`.

### Why step 5 matters

The two layers are **additive, not intersecting**. While the Entra grants from layer 1 are still
in place, the RBAC scope is decorative — the app reaches every mailbox in the tenant regardless
of what the scope says. The setup is therefore only complete after:

```powershell
./setup-azure-app.ps1 -RemoveEntraGraphPermissions
```

which removes the layer-1 grants and leaves the RBAC scope as the only thing in force. Run it
**only after** the authorization test reports `InScope: True`, otherwise the app loses mail
access before it ever had scoped access.

This is also why `setup-azure-app.ps1` **skips the permission-granting step on a re-run** against
an existing app registration: re-granting them while adding a mailbox would silently reopen
tenant-wide access. Use `-EnsureEntraGraphPermissions` if they genuinely have to be re-granted
(e.g. a first run that aborted halfway).

---

## Choosing a mailbox scope option

`-MailboxScopeOption` decides how the management scope selects mailboxes. All four end up
equally restrictive at runtime — **what differs is who can onboard the next mailbox, and what
they need in order to do it.** That is the decision, not security strength.

| Option | Who can add a mailbox | What that takes | Best when |
|---|---|---|---|
| `EmailList` (default) | Only an **Exchange Administrator** | Re-run this script (or `Set-ManagementScope` by hand) | Few, stable mailboxes; every addition should be a deliberate, audited act |
| `CustomAttribute` | Anyone who may **create/edit mailboxes** (Recipient Management) | `Set-Mailbox -CustomAttribute1 …` — one extra field while creating the shared mailbox | Many projects, onboarding delegated to the mail team |
| `SecurityGroup` | The **group owner** — can be a normal user | Add a member (PowerShell, EAC, or Outlook) | You already manage access via groups and want a visible, auditable member list |
| `DomainSuffix` | Anyone who may **create mailboxes** in that domain | Nothing — create the mailbox in the domain | A domain (or subdomain) is reserved exclusively for helpdesk mailboxes |

### `EmailList` — explicit list *(the script's default)*

```powershell
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com", "sales@example.com"
```

Filter: `PrimarySmtpAddress -eq 'helpdesk@example.com' -or PrimarySmtpAddress -eq 'sales@example.com'`

**Benefit:** the most explicit and the most restrictive. The complete set of reachable mailboxes
is written down in exactly one place, and **nobody can grant the plugin access to a mailbox by
themselves** — not the mailbox owner, not whoever creates mailboxes. Every addition passes
through someone holding the Exchange Administrator role. Nothing is ever included implicitly.

**Cost:** exactly that. Each new project needs a privileged admin to run the script. If mailboxes
are onboarded by a team that does *not* hold Exchange Administrator, this option makes them
dependent on someone who does, for every single project.

**Note:** `-MailboxEmailList` is additive — addresses already in the scope are kept. Use
`-ReplaceMailboxList` for "exactly this list" and `-RemoveMailboxEmailList` to revoke.

### `CustomAttribute` — self-service via a mailbox flag

```powershell
./setup-azure-app.ps1 -MailboxScopeOption CustomAttribute `
    -MailboxCustomAttributeValue "Redmine" -TestMailbox "helpdesk@example.com"
```

Filter: `CustomAttribute1 -eq 'Redmine'`

**Benefit:** this is the option that removes the admin bottleneck. `CustomAttribute1` is an
ordinary mailbox property, so **whoever is already allowed to create the shared mailbox can
enable it for the plugin in the same step** — no Exchange Administrator, no script run, no
change to the RBAC scope at all:

```powershell
New-Mailbox -Shared -Name "Sales Helpdesk" -PrimarySmtpAddress "sales@example.com"
Set-Mailbox -Identity "sales@example.com" -CustomAttribute1 "Redmine"
```

Onboarding a project becomes a one-line addition to whatever mailbox-provisioning process
already exists, and the flag travels with the mailbox. It also revokes as easily — clear the
attribute and the mailbox drops out of scope.

**Cost:** the delegation is the risk. Anyone who can edit a mailbox can now put the plugin on it,
so the boundary is only as tight as the Recipient Management role group. `CustomAttribute1`–`15`
are also a **shared, tenant-wide resource** — another team may already be using the one you pick,
so agree on a slot and a value and write it down. The attribute is not prominent in the admin UI,
which makes it easy to set and easy to forget.

### `SecurityGroup` — membership list

```powershell
./setup-azure-app.ps1 -MailboxScopeOption SecurityGroup `
    -MailboxSecurityGroup "helpdesk-mailboxes@example.com" -TestMailbox "helpdesk@example.com"
```

Filter: `MemberOfGroup -eq '<distinguished name of the group>'`

**Benefit:** the middle ground. The set of reachable mailboxes is a visible, reviewable list
rather than a flag hidden on each mailbox, and group membership is something most organisations
already have a process and an audit trail for. Ownership can be delegated to a normal user, so
adding a mailbox needs no admin role at all — and it can be done through the EAC or Outlook
instead of PowerShell.

**Cost:** the group has to be created once (mail-enabled security group) and its ownership
deliberately assigned, so there is more moving furniture than with `CustomAttribute`. Nested
groups are not expanded — members have to be direct. Membership changes also need a moment to
take effect.

### `DomainSuffix` — everything in one domain

```powershell
./setup-azure-app.ps1 -MailboxScopeOption DomainSuffix `
    -MailboxDomainSuffix "@helpdesk.example.com" -TestMailbox "helpdesk@example.com"
```

Filter: `PrimarySmtpAddress -like '*@helpdesk.example.com'`

**Benefit:** zero-touch onboarding. Creating the mailbox in the right domain *is* the entire
process — nothing to set, nothing to remember, no second step to forget.

**Cost:** the domain becomes the security boundary, so it must be reserved for helpdesk mailboxes
and nothing else. Anyone creating a mailbox there grants the plugin access, possibly without
realising it, and there is no per-mailbox opt-out. It also shows: customers see the domain in the
reply address.

---

## Switching options later

A common path is to start with `EmailList` for the first project or two and move to
`CustomAttribute` once the number of projects makes the admin bottleneck hurt. The script handles
that — it rewrites the filter of the existing scope, leaving the app registration, client secret
and role assignments alone:

```powershell
# stamp the mailboxes that are in scope today
Set-Mailbox -Identity "helpdesk@example.com" -CustomAttribute1 "Redmine"
Set-Mailbox -Identity "sales@example.com"    -CustomAttribute1 "Redmine"

# preview the filter change, then apply it
./setup-azure-app.ps1 -MailboxScopeOption CustomAttribute `
    -MailboxCustomAttributeValue "Redmine" -TestMailbox "helpdesk@example.com" -WhatIf
```

Stamp the mailboxes **before** switching the filter — the moment the scope changes, any mailbox
not yet carrying the attribute falls out of scope and its mail fetch starts failing.

---

## Roles needed

| Task | Role |
|---|---|
| Register the app, create the client secret | Application Administrator or Cloud Application Administrator (Entra ID) |
| Grant the Graph application permissions | Same, though granting admin consent for Microsoft Graph app roles may additionally require Privileged Role Administrator or Global Administrator, depending on tenant configuration |
| Create the EXO service principal, scope and role assignments | Exchange Administrator (the `Role Management` role, part of Organization Management) |
| Add a mailbox afterwards | Depends entirely on the scope option — see the table above |

Required PowerShell modules: `Microsoft.Graph` and `ExchangeOnlineManagement`.

---

## Command reference

```powershell
# Preview any scope change: prints old filter, new filter, added and removed addresses
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com" -WhatIf

# Add / remove a mailbox (EmailList option)
./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"
./setup-azure-app.ps1 -RemoveMailboxEmailList "sales@example.com"

# Set the scope to exactly this list, ignoring what is in it now
./setup-azure-app.ps1 -MailboxEmailList "helpdesk@example.com" -ReplaceMailboxList

# Rotate the client secret (the new value must be entered in Redmine)
./setup-azure-app.ps1 -NewClientSecret

# Verify the filter-merge logic offline — connects to nothing, changes nothing
./setup-azure-app.ps1 -SelfTest

# Full teardown
./delete-app-registration.ps1
```

`Get-Help ./setup-azure-app.ps1 -Detailed` documents every parameter.

The script grants access to mailboxes; it does **not** create them. The mailboxes must already
exist in the tenant.

---

## Troubleshooting

**`InScope: False` right after a change.** Expected for a few minutes — Exchange Online needs time
to replicate an RBAC change. The script already retries a few times before reporting a failure.
Do not run `-RemoveEntraGraphPermissions` until it reports `True`.

**"The existing scope filter is not a plain mailbox address list".** The scope was built with a
different `-MailboxScopeOption` (or edited by hand), so merging an address into it would destroy
that filter. Either add the mailbox the way that option expects (attribute, group membership,
domain), or pass `-ReplaceMailboxList` to overwrite the filter deliberately.

**"Multiple app registrations named …".** Every later lookup by display name would be ambiguous.
Remove the obsolete registrations with `delete-app-registration.ps1`, or use a different
`-AppDisplayName`.

**`Connect-MgGraph` fails with "Method not found: …WithLogging".** The `ExchangeOnlineManagement`
module loads an older `Microsoft.Identity.Client` that breaks the Graph SDK afterwards. Start a
fresh PowerShell session; both scripts are ordered to do all Graph work before connecting to
Exchange Online for exactly this reason.

**The mailbox is in scope but Redmine still fails.** The RBAC scope is only half of it — check
that Tenant ID, Client ID and Client Secret are set under *Administration → Plugins → Redmine
expert Helpdesk*, and that the client secret has not expired (`-NewClientSecret` issues a new
one).
