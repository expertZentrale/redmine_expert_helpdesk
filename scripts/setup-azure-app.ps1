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

.PARAMETER Environment
    Which installation to work on — 'LIVE' (default), 'DEV', or any label you
    like. Several installations can live in one tenant side by side; this is
    what keeps them apart, and it is normally the only one of the four
    identifying parameters you need to pass.

    It derives all three of the following, so a DEV stack needs no other names:
      tag             RedmineExpertHelpdesk:DEV
      app registration redmine-expert-helpdesk-dev
      EXO scope        Redmine-expert-Helpdesk-Mailboxes-DEV

.PARAMETER AppDisplayName
    Display name of the app registration in Entra ID. Defaults to
    'redmine-expert-helpdesk-<environment>'.

    Only needed when the installation cannot be found by its tag — see
    -ResourceTag. When it is found by tag, the name it actually carries is used.

.PARAMETER RbacScopeName
    Name of the Exchange Online management scope that restricts mailbox access.
    Defaults to 'Redmine-expert-Helpdesk-Mailboxes-<ENVIRONMENT>'.

    Only used when creating the scope, or when the app has no role assignments
    yet. On a re-run the scope the app is already assigned to wins, so a
    differently named scope is extended rather than duplicated.

.PARAMETER ResourceTag
    Marker written to the app registration's Tags so later runs find the
    installation without knowing the name it was created under. Defaults to
    'RedmineExpertHelpdesk:<ENVIRONMENT>'; existing installations are stamped
    with it on the next run. Every installation additionally carries the plain
    'RedmineExpertHelpdesk' tag, which is how you list all of them in a tenant.
    Set this only if the environment-derived name does not suit you.

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
    # A separate installation for the dev stack, alongside the live one.
    # -Environment derives its own tag, app name and scope name, so the two
    # never collide; every later dev run just repeats -Environment DEV.
    ./setup-azure-app.ps1 -Environment DEV `
        -MailboxEmailList "helpdesk-dev@example.com" `
        -TestMailbox "helpdesk-dev@example.com"

    ./setup-azure-app.ps1 -Environment DEV -MailboxEmailList "sales-dev@example.com"

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
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Environment = "LIVE",

    [string]$AppDisplayName,

    [string]$RbacScopeName,

    [string]$ResourceTag,

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

# Every installation carries two tags: the product tag, shared by all of them
# and useful for taking inventory of a tenant, and the installation tag, which
# is what identifies THIS one. Keeping them separate is what lets a DEV and a
# LIVE installation coexist without either shadowing the other.
$productTag = "RedmineExpertHelpdesk"

<#
Which scope option the supplied mailbox parameters belong to. Each option has
its own parameter, so supplying one says which option was meant — that beats
silently ignoring it in favour of the default.
#>
function Get-ImpliedScopeOption {
    param([string[]]$SuppliedParameters)

    $optionOf = @{
        MailboxDomainSuffix         = "DomainSuffix"
        MailboxSecurityGroup        = "SecurityGroup"
        MailboxCustomAttributeValue = "CustomAttribute"
        MailboxEmailList            = "EmailList"
        RemoveMailboxEmailList      = "EmailList"
    }

    return @(@($SuppliedParameters) |
        Where-Object { $optionOf.ContainsKey($_) } |
        ForEach-Object { $optionOf[$_] } |
        Sort-Object -Unique)
}

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
                throw ("Please provide -MailboxEmailList and/or -RemoveMailboxEmailList.`n" +
                       "  'EmailList' is the default scope option. For a different one, pass its`n" +
                       "  parameter and the option is taken from it:`n" +
                       "    -MailboxDomainSuffix '@helpdesk.example.com'   (DomainSuffix)`n" +
                       "    -MailboxSecurityGroup 'helpdesk-mailboxes'     (SecurityGroup)`n" +
                       "    -MailboxCustomAttributeValue 'Redmine'         (CustomAttribute)")
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

# Single quotes delimit strings in an OData filter and are escaped by doubling
# them. A display name containing an apostrophe would otherwise break the filter
# or silently change what it matches.
function ConvertTo-ODataLiteral {
    param([AllowEmptyString()][string]$Value)

    return ($Value -replace "'", "''")
}

<#
Finds the app registrations carrying the installation marker. The tag is what
makes an installation findable without knowing the name it was created under.
#>
function Find-TaggedApplication {
    param([Parameter(Mandatory)][string]$Tag)

    $literal = ConvertTo-ODataLiteral $Tag
    try {
        return @(Get-MgApplication -Filter "tags/any(t:t eq '$literal')" -All)
    } catch {
        # Some SDK/tenant combinations reject the lambda filter. Scanning
        # client-side is slower but returns the same thing.
        return @(Get-MgApplication -All | Where-Object { @($_.Tags) -contains $Tag })
    }
}

<#
Locates the installation to work on. An explicitly passed display name always
wins; otherwise the marker tag decides, and the display name remains the
fallback so installations created before the tag existed are still found.
#>
function Resolve-HelpdeskApplication {
    param(
        [Parameter(Mandatory)][string]$Tag,
        [Parameter(Mandatory)][string]$DisplayName,
        [switch]$NameWasGiven
    )

    if (-not $NameWasGiven) {
        $tagged = @(Find-TaggedApplication -Tag $Tag)
        if ($tagged.Count -gt 0) {
            return [pscustomobject]@{ Apps = $tagged; FoundBy = "tag '$Tag'" }
        }
    }

    $literal = ConvertTo-ODataLiteral $DisplayName
    return [pscustomobject]@{
        Apps    = @(Get-MgApplication -Filter "DisplayName eq '$literal'")
        FoundBy = "display name '$DisplayName'"
    }
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

<#
The names an -Environment implies. Keeping this in one place is what guarantees
that setup and teardown, and one run and the next, agree on which installation
they are talking about.
#>
function Get-InstallationNames {
    param([Parameter(Mandatory)][string]$Environment)

    $upper = $Environment.ToUpperInvariant()
    $lower = $Environment.ToLowerInvariant()

    return [pscustomobject]@{
        Tag            = "${productTag}:$upper"
        AppDisplayName = "redmine-expert-helpdesk-$lower"
        RbacScopeName  = "Redmine-expert-Helpdesk-Mailboxes-$upper"
    }
}

# PowerShell cannot derive one parameter default from another, so the names that
# follow from -Environment are filled in here. Passing any of them explicitly
# still wins.
$defaultNames = Get-InstallationNames -Environment $Environment

if (-not $ResourceTag)    { $ResourceTag    = $defaultNames.Tag }
if (-not $AppDisplayName) { $AppDisplayName = $defaultNames.AppDisplayName }
if (-not $RbacScopeName)  { $RbacScopeName  = $defaultNames.RbacScopeName }

# Both tags go on the app; only $ResourceTag is used to find it again.
$appTags = @($productTag, $ResourceTag)

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

    Test-Case "each mailbox parameter names its own scope option" {
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxCustomAttributeValue")) @("CustomAttribute")
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxDomainSuffix")) @("DomainSuffix")
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxSecurityGroup")) @("SecurityGroup")
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxEmailList")) @("EmailList")
    }

    # The call site must wrap this in @(): PowerShell unwraps a single-element
    # array on the way out of a function, and indexing the resulting string
    # yields its first character instead of the option name.
    Test-Case "a lone implied option indexes as a whole option name" {
        $implied = @(Get-ImpliedScopeOption -SuppliedParameters @("MailboxCustomAttributeValue"))
        if ($implied[0] -ne "CustomAttribute") { throw "[0] gave '$($implied[0])'" }
    }

    Test-Case "add and remove both mean the EmailList option" {
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxEmailList", "RemoveMailboxEmailList")) `
                   @("EmailList")
    }

    Test-Case "unrelated parameters imply no scope option" {
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("Environment", "AppDisplayName", "TestMailbox")) @()
    }

    Test-Case "parameters of two options are detectable as a conflict" {
        Assert-Set (Get-ImpliedScopeOption -SuppliedParameters @("MailboxEmailList", "MailboxDomainSuffix")) `
                   @("DomainSuffix", "EmailList")
    }

    # If these drift, an existing LIVE installation stops being found by
    # default and a re-run builds a second one beside it.
    Test-Case "the LIVE environment keeps the names installations were created with" {
        $names = Get-InstallationNames -Environment "LIVE"
        if ($names.AppDisplayName -ne "redmine-expert-helpdesk-live") { throw "app: $($names.AppDisplayName)" }
        if ($names.RbacScopeName -ne "Redmine-expert-Helpdesk-Mailboxes-LIVE") { throw "scope: $($names.RbacScopeName)" }
        if ($names.Tag -ne "RedmineExpertHelpdesk:LIVE") { throw "tag: $($names.Tag)" }
    }

    Test-Case "a second environment collides with LIVE in no name at all" {
        $live = Get-InstallationNames -Environment "LIVE"
        $dev  = Get-InstallationNames -Environment "DEV"
        foreach ($field in @("Tag", "AppDisplayName", "RbacScopeName")) {
            if ($live.$field -eq $dev.$field) { throw "$field is shared: $($live.$field)" }
        }
    }

    Test-Case "the environment label is case-insensitive" {
        $lower = Get-InstallationNames -Environment "dev"
        $upper = Get-InstallationNames -Environment "DEV"
        if ($lower.Tag -ne $upper.Tag) { throw "'dev' and 'DEV' disagree: $($lower.Tag) vs $($upper.Tag)" }
        if ($lower.AppDisplayName -ne $upper.AppDisplayName) { throw "app name disagrees" }
    }

    Test-Case "an apostrophe in a display name is escaped for the OData filter" {
        $literal = ConvertTo-ODataLiteral "expert's helpdesk"
        if ($literal -ne "expert''s helpdesk") { throw "got '$literal'" }
    }

    Test-Case "a display name without an apostrophe is left alone" {
        $literal = ConvertTo-ODataLiteral "redmine-expert-helpdesk-live"
        if ($literal -ne "redmine-expert-helpdesk-live") { throw "got '$literal'" }
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
    Connect-MgGraph -Scopes "Application.Read.All", "AppRoleAssignment.ReadWrite.All"

    $lookup = Resolve-HelpdeskApplication -Tag $ResourceTag -DisplayName $AppDisplayName `
                  -NameWasGiven:$PSBoundParameters.ContainsKey('AppDisplayName')

    if ($lookup.Apps.Count -eq 0) {
        throw "No app registration found by $($lookup.FoundBy)."
    }
    if ($lookup.Apps.Count -gt 1) {
        throw ("Several app registrations match the $($lookup.FoundBy):`n" +
               (($lookup.Apps | ForEach-Object { "  $($_.DisplayName)  (AppId $($_.AppId))" }) -join "`n") +
               "`nPass -AppDisplayName to say which one to use.")
    }
    $app = $lookup.Apps[0]
    Write-Host "App registration '$($app.DisplayName)' (AppId $($app.AppId)), found by $($lookup.FoundBy)."

    # Resolve the service principal from the AppId — that link is stable, the
    # display names of the two objects need not agree.
    $sp = @(Get-MgServicePrincipal -Filter "AppId eq '$($app.AppId)'")
    if ($sp.Count -eq 0) {
        throw "No service principal for app '$($app.DisplayName)' (AppId $($app.AppId))."
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

# Take the scope option from the parameters actually supplied. Passing
# -MailboxCustomAttributeValue and getting an error about -MailboxEmailList,
# because the option still sat at its default, is no way to find that out.
# @() around the call because PowerShell unwraps a single-element array on the
# way out of a function — without it a lone result is a string, and [0] indexes
# into its characters.
$impliedOptions = @(Get-ImpliedScopeOption -SuppliedParameters @($PSBoundParameters.Keys))

if ($impliedOptions.Count -gt 1) {
    throw ("The mailbox parameters supplied belong to several scope options (" +
           ($impliedOptions -join ', ') + "). A scope uses exactly one — pass only the " +
           "parameters of the option you want.")
}

if ($PSBoundParameters.ContainsKey('MailboxScopeOption')) {
    if ($impliedOptions.Count -eq 1 -and $impliedOptions[0] -ne $MailboxScopeOption) {
        throw ("-MailboxScopeOption $MailboxScopeOption was given, but the other mailbox " +
               "parameters belong to $($impliedOptions[0]). Drop one of the two so it is " +
               "clear which scope option is meant.")
    }
} elseif ($impliedOptions.Count -eq 1 -and $impliedOptions[0] -ne $MailboxScopeOption) {
    $MailboxScopeOption = $impliedOptions[0]
    Write-Host "Scope option: $MailboxScopeOption (taken from the parameters supplied)." -ForegroundColor DarkGray
}

Confirm-MailboxScopeParameters
if ((-not $TestMailbox) -and $MailboxScopeOption -ne "EmailList") {
    throw ("Please provide -TestMailbox — the address of a helpdesk mailbox that the " +
           "'$MailboxScopeOption' scope should cover, used to verify the RBAC scope. " +
           "For 'CustomAttribute' the mailbox must already carry the attribute value.")
}

Write-Host "== Step 1: Register app ==" -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All"

$lookup = Resolve-HelpdeskApplication -Tag $ResourceTag -DisplayName $AppDisplayName `
              -NameWasGiven:$PSBoundParameters.ContainsKey('AppDisplayName')
$existingApp = $lookup.Apps

if ($existingApp.Count -gt 1) {
    throw ("Several app registrations match the $($lookup.FoundBy):`n" +
           (($existingApp | ForEach-Object { "  $($_.DisplayName)  (AppId $($_.AppId))" }) -join "`n") +
           "`nGive each installation its own -Environment (which derives its own tag and names), " +
           "or pass -AppDisplayName to say which one to extend.")
}

if ($existingApp.Count -eq 1) {
    $isNewApp = $false
    $app = $existingApp[0]

    # Adopt the name the installation actually carries, so everything below —
    # the EXO service principal, the messages — refers to it as it exists
    # rather than to the default this run happened to start from.
    $AppDisplayName = $app.DisplayName
    Write-Host "Existing app registration reused: '$AppDisplayName' (AppId $($app.AppId)), found by $($lookup.FoundBy)." -ForegroundColor Green

    # Stamp installations that predate the marker, so the next run finds them
    # by tag instead of depending on the name being passed in. Existing tags
    # are merged, never replaced — a service principal's tags can carry
    # meaning of their own.
    $missingTags = @($appTags | Where-Object { @($app.Tags) -notcontains $_ })
    if ($missingTags.Count -gt 0) {
        $mergedTags = @(@($app.Tags) + $appTags | Where-Object { $_ } | Sort-Object -Unique)
        if ($PSCmdlet.ShouldProcess($AppDisplayName, "Update-MgApplication -Tags")) {
            Update-MgApplication -ApplicationId $app.Id -Tags $mergedTags
            Write-Host "  marked with tag(s) $($missingTags -join ', ') — later runs find it without -AppDisplayName."
        }
    }

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
    # The tags are what make this installation findable later without knowing
    # the name it was created under.
    $app = New-MgApplication -DisplayName $AppDisplayName -SignInAudience "AzureADMyOrg" -Tags $appTags
    $sp  = New-MgServicePrincipal -AppId $app.AppId
    Write-Host "App registration created, marked with tags $($appTags -join ', ')." -ForegroundColor Green
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
# Purely informational for the summary, so a failure here (e.g. a session
# without a scope that may read app role assignments) must not abort a run that
# has otherwise done its work — report it as unknown instead.
$grantedGraphRoles = $null
try {
    $grantedGraphRoles = @(Get-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id |
        Where-Object { $_.AppRoleId -in @($mailReadWriteId, $mailSendId) })
} catch {
    Write-Host "Could not read the current Graph app role assignments: $($_.Exception.Message)" -ForegroundColor DarkGray
}

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
$exoSpId   = [string]$exoSp.ObjectId
$exoSpName = [string]$exoSp.DisplayName

# The scope name is only a default. Where this app already has role
# assignments, they say which scope the installation actually uses — that beats
# a name, and it stops a re-run from building a second scope merely because
# -RbacScopeName was not passed in.
if (-not $PSBoundParameters.ContainsKey('RbacScopeName')) {
    $ownScopes = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
        Where-Object { $_.Role -in $rbacRoles -and $_.CustomResourceScope -and
                       $_.RoleAssigneeName -eq $exoSpName } |
        ForEach-Object { $_.CustomResourceScope } | Sort-Object -Unique)

    if ($ownScopes.Count -gt 1) {
        throw ("This app is assigned to several scopes (" + ($ownScopes -join ', ') +
               "). Pass -RbacScopeName to say which one to extend.")
    }
    if ($ownScopes.Count -eq 1 -and $ownScopes[0] -ne $RbacScopeName) {
        Write-Host "Using the scope this app is already assigned to: '$($ownScopes[0])'." -ForegroundColor Green
        $RbacScopeName = $ownScopes[0]
    }
}

# 4b. Restrict the management scope to the helpdesk mailboxes.
$scope = Get-ManagementScope -Identity $RbacScopeName -ErrorAction SilentlyContinue

if (-not $scope) {
    # The one way this script can silently fail to honour an existing setup:
    # if the initial setup used different names and they were not passed in, it
    # builds a second, parallel app + scope instead of extending the first.
    # This cannot be checked before step 1 — connecting to Exchange Online
    # breaks the Graph SDK for the rest of the session, so the Graph work has to
    # come first — but saying so here still beats finding out later.
    $otherScopes = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
        Where-Object { $_.Role -in $rbacRoles -and $_.CustomResourceScope -and
                       $_.CustomResourceScope -ne $RbacScopeName })

    if ($otherScopes.Count -gt 0) {
        Write-Host ""
        Write-Host "NOTE: this tenant already has Application Mail.* role assignments on other scopes:" -ForegroundColor Yellow
        foreach ($assignment in $otherScopes) {
            Write-Host "  scope '$($assignment.CustomResourceScope)'  <-  app '$($assignment.RoleAssigneeName)'" -ForegroundColor Yellow
        }
        Write-Host "  If you meant to EXTEND one of those, stop here and re-run with a matching" -ForegroundColor Yellow
        Write-Host "  -RbacScopeName and -AppDisplayName; what this run created so far can be" -ForegroundColor Yellow
        Write-Host "  removed with ./delete-app-registration.ps1 -AppDisplayName '$AppDisplayName'." -ForegroundColor Yellow
        Write-Host "  Continuing sets up a second, parallel installation." -ForegroundColor Yellow
        Write-Host ""
    }

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
Write-Host "Environment:              $Environment" -ForegroundColor Cyan
Write-Host "App registration:         $AppDisplayName (tag '$ResourceTag')" -ForegroundColor Cyan
Write-Host "AppId (Client ID):        $($app.AppId)" -ForegroundColor Cyan
Write-Host "Object ID (SP):           $($sp.Id)" -ForegroundColor Cyan
Write-Host "EXO scope:                $RbacScopeName" -ForegroundColor Cyan
if ($MailboxScopeOption -eq "EmailList") {
    Write-Host "Mailboxes in scope:       $(@($targetAddresses) -join ', ')" -ForegroundColor Cyan
} else {
    Write-Host "Scope filter:             $recipientFilter" -ForegroundColor Cyan
}
# Three states, because "could not read them" must not be reported as "removed".
$graphPermissionState = if ($null -eq $grantedGraphRoles) {
    "unknown (could not be read — check in Entra ID)"
} elseif ($grantedGraphRoles.Count -gt 0) {
    "granted"
} else {
    "removed (only the EXO RBAC scope applies)"
}
Write-Host "Entra Graph permissions:  $graphPermissionState" -ForegroundColor Cyan
Write-Host "=========================================================================" -ForegroundColor Cyan

if ($null -ne $grantedGraphRoles -and $grantedGraphRoles.Count -gt 0) {
    Write-Host "`n=========================================================================" -ForegroundColor Yellow
    Write-Host "IMPORTANT: as long as the Entra Graph permissions from step 2 (Mail.ReadWrite," -ForegroundColor Yellow
    Write-Host "Mail.Send) remain in place, they are additive to the EXO RBAC scope — the app" -ForegroundColor Yellow
    Write-Host "can still access ALL mailboxes in the tenant, regardless of the scope defined" -ForegroundColor Yellow
    Write-Host "above. Once the test above confirms 'InScope: True', re-run this script with" -ForegroundColor Yellow
    Write-Host "-RemoveEntraGraphPermissions:" -ForegroundColor Yellow
    Write-Host "  ./setup-azure-app.ps1 -AppDisplayName '$AppDisplayName' -RemoveEntraGraphPermissions" -ForegroundColor Yellow
    Write-Host "=========================================================================" -ForegroundColor Yellow
}
