<#
.SYNOPSIS
    Set up (and extend) the Azure/Entra app registration for the Redmine expert
    Helpdesk plugin (Microsoft Graph API, OAuth2 Client Credentials Flow).

.DESCRIPTION
    Combines the steps from the plugin documentation (README.md, section
    "Azure App Registration") into a runnable PowerShell script:

      1. Register app + create Service Principal
      2. Assign Graph API permissions (Mail.ReadWrite, Mail.Send) + Admin Consent
      3. Create client secret
      4. Restrict access via Exchange Online Application RBAC to the helpdesk
         mailboxes (replaces the deprecated New-ApplicationAccessPolicy)
      5. Optional: remove the Graph permissions granted in step 2 again, so that
         only the EXO RBAC scope from step 4 applies (see the warning below —
         additive permissions would otherwise defeat the scope)

    The script is re-runnable. Existing resources are honoured: an existing app
    registration, service principal, client secret, Exchange Online service
    principal, management scope and role assignments are reused, never
    duplicated. Running it again with additional -MailboxEmailList addresses
    therefore adds those mailboxes to the existing RBAC scope and leaves
    everything else untouched — the client ID and client secret configured in
    Redmine keep working.

    Note that a re-run against an existing app registration deliberately skips
    step 2: after the initial setup the Entra Graph permissions are removed on
    purpose (step 5), and silently re-granting them would re-open access to
    every mailbox in the tenant. Use -EnsureEntraGraphPermissions to grant them
    explicitly, e.g. after a first run that aborted halfway.

    The script only grants access to mailboxes, it does not create them. The
    mailboxes must already exist in the tenant.

    Required modules:
      - Microsoft.Graph (Microsoft Graph PowerShell SDK)
      - ExchangeOnlineManagement

    Required roles/permissions for the person running it:
      - Application Administrator (or Cloud Application Administrator) in Entra ID
      - Exchange Administrator (for step 4)

.PARAMETER AppDisplayName
    Display name of the app registration in Entra ID.

.PARAMETER RbacScopeName
    Name of the Exchange Online management scope that restricts mailbox access.

.PARAMETER MailboxScopeOption
    Determines how the mailboxes restricted by the Exchange Online RBAC scope
    are selected: 'DomainSuffix', 'SecurityGroup', 'CustomAttribute' or
    'EmailList' (default).

.PARAMETER MailboxDomainSuffix
    Only for -MailboxScopeOption DomainSuffix: domain suffix of the allowed
    mailboxes, e.g. '@helpdesk.example.com'.

.PARAMETER MailboxSecurityGroup
    Only for -MailboxScopeOption SecurityGroup: name/email of the mail-enabled
    security group of allowed mailboxes.

.PARAMETER MailboxCustomAttributeValue
    Only for -MailboxScopeOption CustomAttribute: value of CustomAttribute1 that
    marks the allowed mailboxes.

.PARAMETER MailboxEmailList
    Only for -MailboxScopeOption EmailList: mailbox addresses that must be in the
    RBAC scope, e.g. -MailboxEmailList "a@example.com","b@example.com".

    These addresses are ADDED to the ones already in the scope; addresses that
    are already there are kept. Use -ReplaceMailboxList to set the scope to
    exactly this list instead.

.PARAMETER RemoveMailboxEmailList
    Only for -MailboxScopeOption EmailList: mailbox addresses to remove from the
    RBAC scope. Removing the last address is refused — use
    ./delete-app-registration.ps1 to remove the setup entirely.

.PARAMETER ReplaceMailboxList
    Only for -MailboxScopeOption EmailList: set the scope to exactly
    -MailboxEmailList instead of merging with the addresses already in it.

.PARAMETER SecretValidityYears
    Validity of the client secret in years (default 1).

.PARAMETER NewClientSecret
    Create an additional client secret for an existing app registration (secret
    rotation). Without it, a re-run keeps the existing secret and creates none.

.PARAMETER EnsureEntraGraphPermissions
    Grant the step 2 Graph permissions on an existing app registration. Only
    needed when a first run aborted halfway — see the note in the description.

.PARAMETER TestMailbox
    Mailbox address(es) the RBAC scope is verified against
    (Test-ServicePrincipalAuthorization). Defaults to the addresses added by this
    run; required on a first run of a scope option other than 'EmailList'.

.PARAMETER RemoveEntraGraphPermissions
    Remove the step 2 Graph permissions (Mail.ReadWrite, Mail.Send). Run this
    only AFTER the EXO RBAC test in step 4 succeeded (InScope True) — otherwise
    the app loses all mail access beforehand.

.PARAMETER SelfTest
    Run the offline assertions for the mailbox scope filter helpers and exit.
    Connects to nothing and changes nothing.

.EXAMPLE
    # Initial setup
    ./setup-azure-app.ps1 -AppDisplayName "redmine-helpdesk" `
        -MailboxScopeOption EmailList `
        -MailboxEmailList "helpdesk@example.com", "support@example.com" `
        -TestMailbox "helpdesk@example.com"

.EXAMPLE
    # Later: add another project's mailbox to the existing setup.
    # Nothing else is touched — same app, same client secret.
    ./setup-azure-app.ps1 -MailboxEmailList "sales@example.com"

.EXAMPLE
    # Dry run first: shows the old and the new scope filter, writes nothing.
    ./setup-azure-app.ps1 -MailboxEmailList "sales@example.com" -WhatIf

.EXAMPLE
    # Remove a mailbox from the scope again
    ./setup-azure-app.ps1 -RemoveMailboxEmailList "sales@example.com"

.EXAMPLE
    ./setup-azure-app.ps1 -AppDisplayName "redmine-helpdesk" `
        -MailboxScopeOption DomainSuffix -MailboxDomainSuffix "@helpdesk.example.com" `
        -TestMailbox "helpdesk@example.com"

.EXAMPLE
    # Second run, once the RBAC scope has been successfully tested:
    ./setup-azure-app.ps1 -RemoveEntraGraphPermissions
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$AppDisplayName = "redmine-expert-helpdesk-live",

    [string]$RbacScopeName = "Redmine-expert-Helpdesk-Mailboxes-LIVE",

    [ValidateSet("DomainSuffix", "SecurityGroup", "CustomAttribute", "EmailList")]
    [string]$MailboxScopeOption = "EmailList",

    [string]$MailboxDomainSuffix,

    [string]$MailboxSecurityGroup,

    [string]$MailboxCustomAttributeValue,

    [string[]]$MailboxEmailList,

    [string[]]$RemoveMailboxEmailList,

    [switch]$ReplaceMailboxList,

    [int]$SecretValidityYears = 1,

    [switch]$NewClientSecret,

    [switch]$EnsureEntraGraphPermissions,

    [string[]]$TestMailbox,

    [switch]$RemoveEntraGraphPermissions,

    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"

# Well-known Microsoft Graph app role IDs (stable, tenant-independent)
$graphAppId      = "00000003-0000-0000-c000-000000000000"
$mailReadWriteId = "e2a3a72e-5f79-4c64-b1b1-878b674786c9"
$mailSendId      = "b633e1c5-b582-4048-a93e-9f11b44c7e96"

# The two EXO management roles the scope is assigned to.
$rbacRoles = @("Application Mail.ReadWrite", "Application Mail.Send")

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
            if ((-not $MailboxEmailList -or $MailboxEmailList.Count -eq 0) -and
                (-not $RemoveMailboxEmailList -or $RemoveMailboxEmailList.Count -eq 0)) {
                throw "Please provide -MailboxEmailList and/or -RemoveMailboxEmailList."
            }
        }
    }

    # The list parameters only mean anything when the scope filter is the list.
    if ($MailboxScopeOption -ne "EmailList") {
        if ($RemoveMailboxEmailList -and $RemoveMailboxEmailList.Count -gt 0) {
            throw "-RemoveMailboxEmailList requires -MailboxScopeOption EmailList."
        }
        if ($ReplaceMailboxList) {
            throw "-ReplaceMailboxList requires -MailboxScopeOption EmailList."
        }
    }
}

function Get-MailboxRecipientFilter {
    param([string[]]$EmailList)

    switch ($MailboxScopeOption) {
        "DomainSuffix" {
            return "PrimarySmtpAddress -like '*$MailboxDomainSuffix'"
        }
        "SecurityGroup" {
            # Needs an active Exchange Online connection.
            $groupDn = (Get-Group $MailboxSecurityGroup).DistinguishedName
            return "MemberOfGroup -eq '$groupDn'"
        }
        "CustomAttribute" {
            return "CustomAttribute1 -eq '$MailboxCustomAttributeValue'"
        }
        "EmailList" {
            $clauses = @($EmailList) | ForEach-Object { "PrimarySmtpAddress -eq '$_'" }
            return ($clauses -join " -or ")
        }
    }
}

<#
Extracts the mailbox addresses from an existing RecipientFilter.

Exchange Online normalises and re-parenthesises the filter it stores, so
comparing it as a string against what we wrote is worthless — match the
individual clauses instead, which survives the re-parenthesising.
#>
function Get-MailboxAddressesFromFilter {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Filter)

    $pattern = "PrimarySmtpAddress\s+-eq\s+'([^']+)'"
    $found   = [regex]::Matches($Filter, $pattern)

    # Anything left over besides the address clauses, their -or separators,
    # parentheses and whitespace means the scope was built from a different
    # -MailboxScopeOption or edited by hand. Merging into it would silently
    # destroy that filter, so refuse instead.
    $residue = [regex]::Replace($Filter, $pattern, '')
    $residue = ($residue -replace '-or', '') -replace '[()\s]', ''
    if ($residue) {
        throw ("The existing scope filter is not a plain mailbox address list and " +
               "cannot be merged:`n  $Filter`n" +
               "Use -ReplaceMailboxList to overwrite it, or adjust the scope in " +
               "Exchange Online directly.")
    }

    return @($found | ForEach-Object { $_.Groups[1].Value })
}

<#
Builds the target address list: the existing addresses plus -Add, minus -Remove
(or exactly -Add when -Replace is given).
#>
function Merge-MailboxAddressList {
    param(
        [string[]]$Existing,
        [string[]]$Add,
        [string[]]$Remove,
        [switch]$Replace
    )

    # SMTP addresses are case-insensitive, so compare them that way.
    $drop = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
    foreach ($address in @($Remove)) {
        if (-not [string]::IsNullOrWhiteSpace($address)) { [void]$drop.Add($address.Trim()) }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new(
                [System.StringComparer]::OrdinalIgnoreCase)
    $result = [System.Collections.Generic.List[string]]::new()

    $source = if ($Replace) { @($Add) } else { @($Existing) + @($Add) }
    foreach ($address in $source) {
        if ([string]::IsNullOrWhiteSpace($address)) { continue }
        $trimmed = $address.Trim()
        if ($drop.Contains($trimmed)) { continue }
        if ($seen.Add($trimmed)) { $result.Add($trimmed) }
    }

    if ($result.Count -eq 0) {
        throw ("The resulting mailbox list would be empty. An empty " +
               "RecipientRestrictionFilter is not a valid scope — use " +
               "./delete-app-registration.ps1 to remove the setup entirely.")
    }

    # Sorted so the generated filter string is stable across runs and an
    # unchanged run is detectable as a no-op.
    return @($result | Sort-Object)
}

# Filters only have to be compared loosely — EXO returns its own formatting.
function ConvertTo-ComparableFilter {
    param([AllowEmptyString()][string]$Filter)

    return ((($Filter -replace '[()]', ' ') -replace '\s+', ' ').Trim())
}

<#
Verifies the RBAC scope for one mailbox. EXO needs a moment to replicate a scope
change, so an immediate test can legitimately report InScope False — retry a few
times before calling it a failure.
#>
function Test-MailboxAuthorization {
    param(
        [Parameter(Mandatory)][string]$ServicePrincipalId,
        [Parameter(Mandatory)][string]$Mailbox,
        [int]$RetryCount = 4,
        [int]$RetrySeconds = 15
    )

    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $result = @(Test-ServicePrincipalAuthorization -Identity $ServicePrincipalId -Resource $Mailbox)
        } catch {
            Write-Host "  could not test '$Mailbox': $($_.Exception.Message)" -ForegroundColor Red
            return $false
        }

        $result | Format-Table | Out-String | Write-Host

        $rows = @($result | Where-Object { $_.RoleName -in $rbacRoles })
        if ($rows.Count -eq 0) { $rows = @($result) }
        if ($rows.Count -gt 0 -and -not ($rows | Where-Object { -not $_.InScope })) {
            return $true
        }

        if ($attempt -lt $RetryCount) {
            Write-Host ("  not in scope yet — EXO RBAC changes need a moment to replicate; " +
                        "retrying in ${RetrySeconds}s ($attempt/$RetryCount)") -ForegroundColor DarkGray
            Start-Sleep -Seconds $RetrySeconds
        }
    }

    return $false
}

# -----------------------------------------------------------------------
# Self-test: exercises the filter helpers offline, connects to nothing.
# -----------------------------------------------------------------------
if ($SelfTest) {
    Write-Host "== Self-test: mailbox scope filter helpers ==" -ForegroundColor Cyan

    # The helpers under test are EmailList-only.
    $MailboxScopeOption = "EmailList"
    $failed = 0

    function Test-Case {
        param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][scriptblock]$Body)

        try {
            & $Body
            Write-Host "  PASS  $Name" -ForegroundColor Green
        } catch {
            Write-Host "  FAIL  $Name -> $($_.Exception.Message)" -ForegroundColor Red
            $script:failed++
        }
    }

    function Assert-Set {
        param([string[]]$Actual, [string[]]$Expected)

        $a = @($Actual) | Sort-Object
        $e = @($Expected) | Sort-Object
        if (($a -join '|') -ine ($e -join '|')) {
            throw "expected [$($e -join ', ')] but got [$($a -join ', ')]"
        }
    }

    function Assert-Throws {
        param([Parameter(Mandatory)][scriptblock]$Body)

        try { & $Body } catch { return }
        throw "expected an exception, but none was thrown"
    }

    Test-Case "generated filter parses back to the same addresses" {
        $addresses = @("a@example.com", "b@example.com")
        $filter    = Get-MailboxRecipientFilter -EmailList $addresses
        Assert-Set (Get-MailboxAddressesFromFilter -Filter $filter) $addresses
    }

    Test-Case "parses the parenthesised form Exchange Online stores" {
        $filter = "((PrimarySmtpAddress -eq 'a@example.com') -or (PrimarySmtpAddress -eq 'b@example.com'))"
        Assert-Set (Get-MailboxAddressesFromFilter -Filter $filter) @("a@example.com", "b@example.com")
    }

    Test-Case "parses a single-address filter" {
        Assert-Set (Get-MailboxAddressesFromFilter -Filter "PrimarySmtpAddress -eq 'a@example.com'") `
                   @("a@example.com")
    }

    Test-Case "adding an address keeps the existing ones" {
        Assert-Set (Merge-MailboxAddressList -Existing @("a@example.com", "b@example.com") `
                                             -Add @("c@example.com")) `
                   @("a@example.com", "b@example.com", "c@example.com")
    }

    Test-Case "adding a known address does not duplicate it" {
        Assert-Set (Merge-MailboxAddressList -Existing @("a@example.com", "b@example.com") `
                                             -Add @("a@example.com")) `
                   @("a@example.com", "b@example.com")
    }

    Test-Case "duplicate detection is case-insensitive" {
        Assert-Set (Merge-MailboxAddressList -Existing @("A@Example.com") `
                                             -Add @("a@example.com")) `
                   @("A@Example.com")
    }

    Test-Case "removing an address keeps the rest" {
        Assert-Set (Merge-MailboxAddressList -Existing @("a@example.com", "b@example.com", "c@example.com") `
                                             -Remove @("B@example.com")) `
                   @("a@example.com", "c@example.com")
    }

    Test-Case "replace sets the list verbatim" {
        Assert-Set (Merge-MailboxAddressList -Existing @("a@example.com", "b@example.com") `
                                             -Add @("c@example.com") -Replace) `
                   @("c@example.com")
    }

    Test-Case "the merged list is sorted, so an unchanged run is a no-op" {
        $first  = Merge-MailboxAddressList -Existing @("b@example.com") -Add @("a@example.com")
        $second = Merge-MailboxAddressList -Existing $first -Add @("a@example.com")
        if ((Get-MailboxRecipientFilter -EmailList $first) -ne (Get-MailboxRecipientFilter -EmailList $second)) {
            throw "filter changed between two equivalent runs"
        }
    }

    Test-Case "removing the last address is refused" {
        Assert-Throws { Merge-MailboxAddressList -Existing @("a@example.com") -Remove @("a@example.com") }
    }

    Test-Case "a CustomAttribute filter is not merged blindly" {
        Assert-Throws { Get-MailboxAddressesFromFilter -Filter "CustomAttribute1 -eq 'Redmine'" }
    }

    Test-Case "a DomainSuffix filter is not merged blindly" {
        Assert-Throws { Get-MailboxAddressesFromFilter -Filter "PrimarySmtpAddress -like '*@example.com'" }
    }

    Test-Case "a mixed filter is not merged blindly" {
        Assert-Throws {
            Get-MailboxAddressesFromFilter `
                -Filter "PrimarySmtpAddress -eq 'a@example.com' -and CustomAttribute1 -eq 'Redmine'"
        }
    }

    if ($failed -gt 0) {
        Write-Host "`n$failed self-test(s) failed." -ForegroundColor Red
        exit 1
    }

    Write-Host "`nAll self-tests passed." -ForegroundColor Green
    exit 0
}

# -----------------------------------------------------------------------
# Step 5: remove the Entra Graph permissions again, once the EXO RBAC scope
# has been successfully tested.
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
               ($sp.AppId -join ', ') + "). Delete obsolete ones first.")
    }
    $sp = $sp[0]

    $assignments = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
        Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) })

    if ($assignments.Count -eq 0) {
        Write-Host "Nothing to do — no Mail.ReadWrite/Mail.Send assignments present."
        return
    }

    foreach ($assignment in $assignments) {
        Remove-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $sp.Id `
            -AppRoleAssignmentId $assignment.Id
    }

    Write-Host "Done. Entra permissions removed. Only the EXO RBAC scope applies from now on." -ForegroundColor Green
    return
}

# -----------------------------------------------------------------------
# Step 1: Register app and create Service Principal
# -----------------------------------------------------------------------
# Validate everything before the first resource is created — aborting
# halfway leaves orphaned app registrations behind.
Confirm-MailboxScopeParameters
if ((-not $TestMailbox) -and $MailboxScopeOption -ne "EmailList") {
    throw "Please provide -TestMailbox (address of a helpdesk mailbox used to verify the RBAC scope)."
}

Write-Host "== Step 1: Register app ==" -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All"

# More than one match makes every later DisplayName lookup ambiguous.
$existingApp = @(Get-MgApplication -Filter "DisplayName eq '$AppDisplayName'")
if ($existingApp.Count -gt 1) {
    throw ("Multiple app registrations named '$AppDisplayName' exist (AppIds: " +
           ($existingApp.AppId -join ', ') + "). Delete the obsolete ones or use a " +
           "different -AppDisplayName.")
}

if ($existingApp.Count -eq 1) {
    $isNewApp = $false
    $app = $existingApp[0]
    Write-Host "Existing app registration reused (AppId $($app.AppId))." -ForegroundColor Green

    $sp = @(Get-MgServicePrincipal -Filter "AppId eq '$($app.AppId)'")
    if ($sp.Count -eq 0) {
        # Everything below needs the object ID, so there is nothing to preview.
        if ($WhatIfPreference) {
            throw ("The app registration '$AppDisplayName' has no service principal yet. " +
                   "Run without -WhatIf to complete the setup first.")
        }
        Write-Host "No service principal for this app yet — creating it."
        $sp = New-MgServicePrincipal -AppId $app.AppId
    } else {
        $sp = $sp[0]
    }
} else {
    # -WhatIf is meant for re-runs against an existing installation; on a fresh
    # tenant there is nothing to preview and every later step would run into a
    # null reference.
    if ($WhatIfPreference) {
        throw ("-WhatIf requires an existing app registration named '$AppDisplayName'. " +
               "Run the initial setup without -WhatIf.")
    }

    $isNewApp = $true
    $app = New-MgApplication -DisplayName $AppDisplayName -SignInAudience "AzureADMyOrg"
    $sp  = New-MgServicePrincipal -AppId $app.AppId
    Write-Host "App registration created." -ForegroundColor Green
}

Write-Host "AppId (Client ID):        $($app.AppId)"
Write-Host "Object ID (SP):           $($sp.Id)"
Write-Host "Tenant ID:                $((Get-MgContext).TenantId)"

# -----------------------------------------------------------------------
# Step 2: Grant Graph API permissions + Admin Consent
# -----------------------------------------------------------------------
Write-Host "`n== Step 2: Grant API permissions + Admin Consent ==" -ForegroundColor Cyan

if ($isNewApp -or $EnsureEntraGraphPermissions) {
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

    $grantedRoleIds = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
        Select-Object -ExpandProperty AppRoleId)

    foreach ($roleId in @($mailReadWriteId, $mailSendId)) {
        if ($grantedRoleIds -contains $roleId) {
            Write-Host "  app role $roleId already granted."
            continue
        }
        New-MgServicePrincipalAppRoleAssignment `
            -ServicePrincipalId $sp.Id `
            -PrincipalId $sp.Id `
            -ResourceId $graphSp.Id `
            -AppRoleId $roleId | Out-Null
    }

    Write-Host "Permissions assigned and Admin Consent granted (Mail.ReadWrite, Mail.Send)."
} else {
    Write-Host "Skipped — the app registration already exists."
    Write-Host "  After the initial setup these permissions are removed on purpose (step 5) so"
    Write-Host "  that only the EXO RBAC scope is in force. Re-granting them here would give the"
    Write-Host "  app access to every mailbox in the tenant again."
    Write-Host "  Use -EnsureEntraGraphPermissions if they really have to be (re-)granted."
}

# Capture this before connecting to Exchange Online: the EXO module loads an
# older Microsoft.Identity.Client, which breaks Graph calls afterwards.
$grantedGraphRoles = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
    Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) })

# -----------------------------------------------------------------------
# Step 3: Create client secret
# -----------------------------------------------------------------------
Write-Host "`n== Step 3: Create client secret ==" -ForegroundColor Cyan

if ($isNewApp -or $NewClientSecret) {
    $secret = Add-MgApplicationPassword -ApplicationId $app.Id `
        -PasswordCredential @{
            DisplayName = "$AppDisplayName-secret"
            EndDateTime = (Get-Date).AddYears($SecretValidityYears)
        }

    # The value is shown only once — save it immediately!
    Write-Host "Client Secret: $($secret.SecretText)" -ForegroundColor Yellow
    Write-Host "IMPORTANT: Save this value now (e.g. in the Redmine plugin configuration), it will not be shown again." -ForegroundColor Yellow
} else {
    Write-Host "Skipped — keeping the existing client secret, the one configured in Redmine stays valid."
    Write-Host "Use -NewClientSecret to create an additional one (rotation). Existing secrets:"
    foreach ($credential in @($app.PasswordCredentials)) {
        Write-Host "  $($credential.DisplayName) — expires $($credential.EndDateTime)"
    }
}

# -----------------------------------------------------------------------
# Step 4: Restrict access via Exchange Online Application RBAC
# -----------------------------------------------------------------------
Write-Host "`n== Step 4: Set up Exchange Online Application RBAC ==" -ForegroundColor Cyan
Connect-ExchangeOnline

# 4a. Register the Service Principal in Exchange Online.
#     AppId    = "Application ID" from Entra ID -> Enterprise applications
#     ObjectId = "Object ID"      from Entra ID -> Enterprise applications
#     (NOT the IDs from "App registrations" — those are different!)
$exoSp = @(Get-ServicePrincipal -ErrorAction SilentlyContinue | Where-Object { $_.AppId -eq $app.AppId })
if ($exoSp.Count -eq 0) {
    if ($PSCmdlet.ShouldProcess($AppDisplayName, "New-ServicePrincipal")) {
        New-ServicePrincipal `
            -AppId $app.AppId `
            -ObjectId $sp.Id `
            -DisplayName $AppDisplayName | Out-Null
    }
    $exoSp = Get-ServicePrincipal -Identity $sp.Id
} else {
    $exoSp = $exoSp[0]
    Write-Host "EXO service principal already registered (ObjectId $($exoSp.ObjectId))."
}
$exoSpId = [string]$exoSp.ObjectId

# 4b. Restrict the management scope to the helpdesk mailboxes.
$scope = Get-ManagementScope -Identity $RbacScopeName -ErrorAction SilentlyContinue

if (-not $scope) {
    if ($MailboxScopeOption -eq "EmailList") {
        $targetAddresses = Merge-MailboxAddressList -Existing @() `
                                                    -Add $MailboxEmailList `
                                                    -Remove $RemoveMailboxEmailList
        $recipientFilter = Get-MailboxRecipientFilter -EmailList $targetAddresses
        $addedAddresses  = $targetAddresses
    } else {
        $recipientFilter = Get-MailboxRecipientFilter
        $targetAddresses = @()
        $addedAddresses  = @()
    }

    Write-Host "Creating management scope '$RbacScopeName'"
    Write-Host "  filter: $recipientFilter"
    if ($PSCmdlet.ShouldProcess($RbacScopeName, "New-ManagementScope")) {
        New-ManagementScope `
            -Name $RbacScopeName `
            -RecipientRestrictionFilter $recipientFilter | Out-Null
    }
} else {
    $addedAddresses   = @()
    $removedAddresses = @()

    if ($MailboxScopeOption -eq "EmailList") {
        if ($ReplaceMailboxList) {
            # Skip parsing entirely — this is also the way out of a scope whose
            # filter Get-MailboxAddressesFromFilter refuses to merge.
            $currentAddresses = @()
        } else {
            if ([string]::IsNullOrWhiteSpace($scope.RecipientFilter)) {
                throw ("The existing scope '$RbacScopeName' has no recipient filter to merge " +
                       "into. Use -ReplaceMailboxList to set it explicitly.")
            }
            $currentAddresses = Get-MailboxAddressesFromFilter -Filter $scope.RecipientFilter
        }

        $targetAddresses = Merge-MailboxAddressList -Existing $currentAddresses `
                                                    -Add $MailboxEmailList `
                                                    -Remove $RemoveMailboxEmailList `
                                                    -Replace:$ReplaceMailboxList

        $addedAddresses   = @($targetAddresses  | Where-Object { $_ -notin $currentAddresses })
        $removedAddresses = @($currentAddresses | Where-Object { $_ -notin $targetAddresses })

        $recipientFilter = Get-MailboxRecipientFilter -EmailList $targetAddresses
        $isUnchanged     = ($addedAddresses.Count -eq 0 -and $removedAddresses.Count -eq 0)
    } else {
        $targetAddresses = @()
        $recipientFilter = Get-MailboxRecipientFilter
        $isUnchanged     = ((ConvertTo-ComparableFilter $scope.RecipientFilter) -ieq
                            (ConvertTo-ComparableFilter $recipientFilter))
    }

    Write-Host "Management scope '$RbacScopeName' already exists."
    Write-Host "  old filter: $($scope.RecipientFilter)"
    Write-Host "  new filter: $recipientFilter"
    if ($addedAddresses.Count -gt 0) {
        Write-Host "  added:   $($addedAddresses -join ', ')" -ForegroundColor Green
    }
    if ($removedAddresses.Count -gt 0) {
        Write-Host "  removed: $($removedAddresses -join ', ')" -ForegroundColor Yellow
    }

    if ($isUnchanged) {
        Write-Host "  unchanged — nothing to do."
    } elseif ($PSCmdlet.ShouldProcess($RbacScopeName, "Set-ManagementScope")) {
        Set-ManagementScope -Identity $RbacScopeName -RecipientRestrictionFilter $recipientFilter | Out-Null
        Write-Host "  scope updated." -ForegroundColor Green
    }
}

# 4c. Assign the roles to the scope. Look the service principal up by ObjectId,
#     because DisplayName is ambiguous.
#     Get-ManagementRoleAssignment has no -CustomResourceScope filter, so filter
#     client-side.
$exoSpName = [string]$exoSp.DisplayName
$existingAssignments = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
    Where-Object { $_.CustomResourceScope -eq $RbacScopeName -and $_.RoleAssigneeName -eq $exoSpName })

foreach ($role in $rbacRoles) {
    if ($existingAssignments | Where-Object { $_.Role -eq $role }) {
        Write-Host "Role assignment '$role' on scope '$RbacScopeName' already exists."
        continue
    }
    if ($PSCmdlet.ShouldProcess("$role -> $RbacScopeName", "New-ManagementRoleAssignment")) {
        New-ManagementRoleAssignment `
            -App $exoSpId `
            -Role $role `
            -CustomResourceScope $RbacScopeName | Out-Null
        Write-Host "Role assignment '$role' created." -ForegroundColor Green
    }
}

# 4d. Test access (InScope must be True).
$testMailboxes = @($TestMailbox | Where-Object { $_ })
if ($testMailboxes.Count -eq 0) {
    # Nothing given explicitly — verify what this run just added.
    $testMailboxes = @($addedAddresses)
}

if ($WhatIfPreference) {
    Write-Host "`nSkipping the authorization test (-WhatIf)."
} elseif ($testMailboxes.Count -eq 0) {
    Write-Host "`nNo mailbox to test — pass -TestMailbox to verify the scope explicitly."
} else {
    $notInScope = @()
    foreach ($mailbox in $testMailboxes) {
        Write-Host "`nTesting authorization for mailbox '$mailbox':"
        if (-not (Test-MailboxAuthorization -ServicePrincipalId $exoSpId -Mailbox $mailbox)) {
            $notInScope += $mailbox
        }
    }

    if ($notInScope.Count -gt 0) {
        Write-Host ("`nNot in scope: " + ($notInScope -join ', ')) -ForegroundColor Red
        Write-Host "Do NOT run -RemoveEntraGraphPermissions until this is resolved." -ForegroundColor Red
    } else {
        Write-Host "`nAll tested mailboxes are in scope." -ForegroundColor Green
    }
}

# -----------------------------------------------------------------------
# Summary
# -----------------------------------------------------------------------
Write-Host "`n=========================================================================" -ForegroundColor Cyan
Write-Host "AppId (Client ID):        $($app.AppId)" -ForegroundColor Cyan
Write-Host "Object ID (SP):           $($sp.Id)" -ForegroundColor Cyan
Write-Host "EXO scope:                $RbacScopeName" -ForegroundColor Cyan
if ($MailboxScopeOption -eq "EmailList") {
    Write-Host "Mailboxes in scope:       $(@($targetAddresses) -join ', ')" -ForegroundColor Cyan
} else {
    Write-Host "Scope filter:             $recipientFilter" -ForegroundColor Cyan
}
Write-Host "Entra Graph permissions:  $(if ($grantedGraphRoles.Count -gt 0) { 'granted' } else { 'removed (only the EXO RBAC scope applies)' })" -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan

if ($grantedGraphRoles.Count -gt 0) {
    Write-Host "`n=========================================================================" -ForegroundColor Yellow
    Write-Host "IMPORTANT: as long as the Entra Graph permissions from step 2 (Mail.ReadWrite," -ForegroundColor Yellow
    Write-Host "Mail.Send) remain in place, they are additive to the EXO RBAC scope — the app" -ForegroundColor Yellow
    Write-Host "can still access ALL mailboxes in the tenant, regardless of the scope defined" -ForegroundColor Yellow
    Write-Host "above. Once the test above confirms 'InScope: True', re-run this script with" -ForegroundColor Yellow
    Write-Host "-RemoveEntraGraphPermissions:" -ForegroundColor Yellow
    Write-Host "  ./setup-azure-app.ps1 -AppDisplayName '$AppDisplayName' -RemoveEntraGraphPermissions" -ForegroundColor Yellow
    Write-Host "=========================================================================" -ForegroundColor Yellow
}
