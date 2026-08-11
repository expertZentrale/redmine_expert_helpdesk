<#
.SYNOPSIS
    One-time setup of the Azure/Entra app registration for the Redmine Expert
    Helpdesk plugin (Microsoft Graph API, OAuth2 Client Credentials Flow).

.DESCRIPTION
    Combines all steps from the plugin documentation (README.md, section
    "Azure App Registration") into a single runnable PowerShell script:

      1. Register the app + create a Service Principal
      2. Assign Graph API permissions (Mail.ReadWrite, Mail.Send) + Admin Consent
      3. Create a client secret
      4. Restrict access via Exchange Online Application RBAC to the helpdesk
         mailboxes (replaces the deprecated New-ApplicationAccessPolicy)
      5. Optional: remove the Graph permissions granted in step 2 again, so
         that only the EXO RBAC scope from step 4 applies (see the warning
         below — additive permissions would otherwise defeat the scope)

    Required modules:
      - Microsoft.Graph (Microsoft Graph PowerShell SDK)
      - ExchangeOnlineManagement

    Required roles/permissions for the person running this:
      - Application Administrator (or Cloud Application Administrator) in Entra ID
      - Exchange Administrator (for step 4)

.PARAMETER AppDisplayName
    Display name of the app registration in Entra ID.

.PARAMETER MailboxScopeOption
    Determines how mailboxes are restricted for the Exchange Online RBAC
    scope: 'DomainSuffix' (default), 'SecurityGroup', 'CustomAttribute' or
    'EmailList'.

.PARAMETER MailboxDomainSuffix
    Only with -MailboxScopeOption DomainSuffix: domain suffix of the allowed
    mailboxes, e.g. '@helpdesk.example.com'.

.PARAMETER MailboxSecurityGroup
    Only with -MailboxScopeOption SecurityGroup: name/email of the
    mail-enabled security group containing the allowed mailboxes.

.PARAMETER MailboxCustomAttributeValue
    Only with -MailboxScopeOption CustomAttribute: value of CustomAttribute1
    that marks the allowed mailboxes.

.PARAMETER MailboxEmailList
    Only with -MailboxScopeOption EmailList: fixed list of allowed mailbox
    addresses, e.g. -MailboxEmailList "a@example.com","b@example.com".

.PARAMETER SecretValidityYears
    Validity period of the client secret in years (default: 1).

.PARAMETER TestMailbox
    Required (except with -RemoveEntraGraphPermissions): address of a helpdesk
    mailbox to test the RBAC scope against after setup
    (Test-ServicePrincipalAuthorization).

.PARAMETER RemoveEntraGraphPermissions
    Switch: removes the Graph app roles assigned in step 2 (Mail.ReadWrite,
    Mail.Send) again. Only enable this AFTER the EXO RBAC test in step 4 has
    succeeded (InScope = True) — otherwise the app loses all mail access
    beforehand.

.EXAMPLE
    ./setup-azure-app.ps1 -AppDisplayName "redmine-helpdesk" `
        -MailboxScopeOption DomainSuffix -MailboxDomainSuffix "@helpdesk.example.com" `
        -TestMailbox "helpdesk@example.com"

.EXAMPLE
    ./setup-azure-app.ps1 -AppDisplayName "redmine-helpdesk" `
        -MailboxScopeOption EmailList `
        -MailboxEmailList "helpdesk@example.com", "support@example.com" `
        -TestMailbox "helpdesk@example.com"

.EXAMPLE
    # Second run, after the RBAC scope has been successfully tested:
    ./setup-azure-app.ps1 -RemoveEntraGraphPermissions
#>

[CmdletBinding()]
param(
    [string]$AppDisplayName = "redmine-expert-helpdesk-live",

    [ValidateSet("DomainSuffix", "SecurityGroup", "CustomAttribute", "EmailList")]
    [string]$MailboxScopeOption = "EmailList",

    [string]$MailboxDomainSuffix,

    [string]$MailboxSecurityGroup,

    [string]$MailboxCustomAttributeValue,

    [string[]]$MailboxEmailList,

    [int]$SecretValidityYears = 1,

    [string]$TestMailbox,

    [switch]$RemoveEntraGraphPermissions
)

$ErrorActionPreference = "Stop"

# Well-known Microsoft Graph app role IDs (stable, tenant-independent)
$graphAppId      = "00000003-0000-0000-c000-000000000000"
$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"
$rbacScopeName   = "Redmine-expert-Helpdesk-Mailboxes-LIVE"

function Confirm-MailboxScopeParameters {
    switch ($MailboxScopeOption) {
        "DomainSuffix" {
            if (-not $MailboxDomainSuffix) {
                throw "Please provide -MailboxDomainSuffix (e.g. '@helpdesk.example.com')."
            }
        }
        "SecurityGroup" {
            if (-not $MailboxSecurityGroup) {
                throw "Please provide -MailboxSecurityGroup."
            }
        }
        "CustomAttribute" {
            if (-not $MailboxCustomAttributeValue) {
                throw "Please provide -MailboxCustomAttributeValue."
            }
        }
        "EmailList" {
            if (-not $MailboxEmailList -or $MailboxEmailList.Count -eq 0) {
                throw "Please provide -MailboxEmailList with at least one address."
            }
        }
    }
}

function Get-MailboxRecipientFilter {
    switch ($MailboxScopeOption) {
        "DomainSuffix" {
            return "PrimarySmtpAddress -like '*$MailboxDomainSuffix'"
        }
        "SecurityGroup" {
            # Requires an active Exchange Online connection.
            $dn = (Get-Group $MailboxSecurityGroup).DistinguishedName
            return "MemberOfGroup -eq '$dn'"
        }
        "CustomAttribute" {
            return "CustomAttribute1 -eq '$MailboxCustomAttributeValue'"
        }
        "EmailList" {
            $clauses = $MailboxEmailList | ForEach-Object { "PrimarySmtpAddress -eq '$_'" }
            return ($clauses -join " -or ")
        }
    }
}

# -----------------------------------------------------------------------
# Step 5 (separate run): only remove Entra Graph permissions, after the
# EXO RBAC scope has already been successfully tested.
# -----------------------------------------------------------------------
if ($RemoveEntraGraphPermissions) {
    Write-Host "== Step 5: Remove Entra Graph permissions ==" -ForegroundColor Cyan
    Connect-MgGraph -Scopes "AppRoleAssignment.ReadWrite.All"

    $sp = @(Get-MgServicePrincipal -Filter "DisplayName eq '$AppDisplayName'")
    if ($sp.Count -eq 0) {
        throw "Service Principal '$AppDisplayName' not found."
    }
    if ($sp.Count -gt 1) {
        throw ("Multiple Service Principals named '$AppDisplayName' found (AppIds: " +
               ($sp.AppId -join ', ') + "). Delete the obsolete ones first.")
    }
    $sp = $sp[0]

    Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
        Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) } |
        ForEach-Object {
            Remove-MgServicePrincipalAppRoleAssignment `
                -ServicePrincipalId  $sp.Id `
                -AppRoleAssignmentId $_.Id
        }

    Write-Host "Done. Entra permissions removed. Only the EXO RBAC scope applies from now on." -ForegroundColor Green
    return
}

# -----------------------------------------------------------------------
# Step 1: Register the app + create a Service Principal
# -----------------------------------------------------------------------
# Validate everything before the first resource is created — a run aborting
# halfway leaves orphaned app registrations behind.
Confirm-MailboxScopeParameters
if (-not $TestMailbox) {
    throw "Please provide -TestMailbox (address of a helpdesk mailbox used to verify the RBAC scope)."
}

Write-Host "== Step 1: Register the app ==" -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All"

# Abort on duplicates — otherwise later lookups by DisplayName become ambiguous.
$existingApp = @(Get-MgApplication -Filter "DisplayName eq '$AppDisplayName'")
if ($existingApp.Count -gt 0) {
    throw ("An app registration named '$AppDisplayName' already exists (AppIds: " +
           ($existingApp.AppId -join ', ') + "). Delete it or use a different -AppDisplayName.")
}

$app = New-MgApplication `
    -DisplayName    $AppDisplayName `
    -SignInAudience "AzureADMyOrg"   # Single Tenant

# Service Principal is required for Admin Consent
$sp = New-MgServicePrincipal -AppId $app.AppId

$tenantId = (Get-MgContext).TenantId
Write-Host "AppId (Client ID):  $($app.AppId)"
Write-Host "Object ID (SP):     $($sp.Id)"
Write-Host "Tenant ID:          $tenantId"

# -----------------------------------------------------------------------
# Step 2: Grant API permissions + Admin Consent
# -----------------------------------------------------------------------
Write-Host "`n== Step 2: Grant API permissions + Admin Consent ==" -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All", "AppRoleAssignment.ReadWrite.All"

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

Write-Host "Permissions assigned and Admin Consent granted (Mail.ReadWrite, Mail.Send)."

# -----------------------------------------------------------------------
# Step 3: Create a client secret
# -----------------------------------------------------------------------
Write-Host "`n== Step 3: Create a client secret ==" -ForegroundColor Cyan
$secret = Add-MgApplicationPassword -ApplicationId $app.Id `
    -PasswordCredential @{
        DisplayName = "$AppDisplayName-secret"
        EndDateTime = (Get-Date).AddYears($SecretValidityYears)
    }

# Value is shown only once — save it immediately!
Write-Host "Client Secret: $($secret.SecretText)" -ForegroundColor Yellow
Write-Host "IMPORTANT: Save this value now (e.g. in the Redmine plugin configuration), it will not be shown again." -ForegroundColor Yellow

# -----------------------------------------------------------------------
# Step 4: Restrict access via Exchange Online Application RBAC
# -----------------------------------------------------------------------
Write-Host "`n== Step 4: Set up Exchange Online Application RBAC ==" -ForegroundColor Cyan
Connect-ExchangeOnline

# 4a. Register the Service Principal in Exchange Online.
#     AppId    = "Application ID"  from Entra ID -> Enterprise Applications
#     ObjectId = "Object ID"       from Entra ID -> Enterprise Applications
#     (NOT the IDs from "App registrations" — they are different!)
New-ServicePrincipal `
    -AppId       $app.AppId `
    -ObjectId    $sp.Id `
    -DisplayName $AppDisplayName

# 4b. Restrict the management scope to the helpdesk mailboxes.
$recipientFilter = Get-MailboxRecipientFilter
New-ManagementScope `
    -Name $rbacScopeName `
    -RecipientRestrictionFilter $recipientFilter

# 4c. Assign roles.
#     Look up by ObjectId (unique) — the DisplayName may exist more than once.
$exoSp   = Get-ServicePrincipal -Identity $sp.Id
$exoSpId = [string]$exoSp.ObjectId
New-ManagementRoleAssignment `
    -App  $exoSpId `
    -Role "Application Mail.ReadWrite" `
    -CustomResourceScope $rbacScopeName
New-ManagementRoleAssignment `
    -App  $exoSpId `
    -Role "Application Mail.Send" `
    -CustomResourceScope $rbacScopeName

Write-Host "EXO RBAC scope '$rbacScopeName' set up (filter: $recipientFilter)."

# 4d. Test access (InScope must be true).
Write-Host "`nTesting authorization for mailbox '$TestMailbox':"
Test-ServicePrincipalAuthorization `
    -Identity $exoSpId `
    -Resource $TestMailbox | Format-Table

Write-Host "`n=========================================================================" -ForegroundColor Yellow
Write-Host "IMPORTANT: As long as the Entra Graph permissions from step 2 (Mail.ReadWrite," -ForegroundColor Yellow
Write-Host "Mail.Send) remain in place, they are additive to the EXO RBAC scope — the app" -ForegroundColor Yellow
Write-Host "can then still access ALL mailboxes in the tenant, regardless of the scope" -ForegroundColor Yellow
Write-Host "defined above. Once the test above confirms 'InScope: True', re-run this" -ForegroundColor Yellow
Write-Host "script with -RemoveEntraGraphPermissions:" -ForegroundColor Yellow
Write-Host "  ./setup-azure-app.ps1 -AppDisplayName '$AppDisplayName' -RemoveEntraGraphPermissions" -ForegroundColor Yellow
Write-Host "=========================================================================" -ForegroundColor Yellow