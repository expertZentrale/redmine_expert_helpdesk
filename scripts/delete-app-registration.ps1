<#
.SYNOPSIS
    Removes all objects created by azure-app-registration.ps1 (clean slate).

.DESCRIPTION
    Shows every object that would be deleted and asks for confirmation before
    each single destructive action. Covers:
      - the Entra ID app registration(s)
      - the soft-deleted app registration(s) in the 30-day recycle bin
      - Exchange Online management role assignments on the RBAC scope
      - the Exchange Online management scope
      - the Exchange Online service principal(s)

.PARAMETER Environment
    Which installation to remove — 'LIVE' (default), 'DEV', or whatever label
    it was set up with. Derives the tag and both names, so removing the dev
    installation is '-Environment DEV' and nothing else.

.PARAMETER AppDisplayName
    Display name of the app registration / service principal to remove. Only
    needed when the installation cannot be found by its tag — see -ResourceTag.

.PARAMETER ResourceTag
    Marker that setup-azure-app.ps1 writes to the app registration's Tags. It is
    what finds the installation when it was created under a different name;
    -AppDisplayName is the fallback. Defaults to
    'RedmineExpertHelpdesk:<ENVIRONMENT>'.

.PARAMETER RbacScopeName
    Name of the Exchange Online management scope to remove.

.PARAMETER Force
    Skip all confirmation prompts.

.EXAMPLE
    ./delete-app-registration.ps1

.EXAMPLE
    # Remove only the dev installation, leaving the live one alone
    ./delete-app-registration.ps1 -Environment DEV
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')]
    [string]$Environment = "LIVE",

    [string]$AppDisplayName,

    [string]$ResourceTag,

    [string]$RbacScopeName,

    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Mirrors setup-azure-app.ps1: PowerShell cannot derive one parameter default
# from another, so the names that follow from -Environment are filled in here.
$productTag = "RedmineExpertHelpdesk"
$envUpper   = $Environment.ToUpperInvariant()
$envLower   = $Environment.ToLowerInvariant()

if (-not $ResourceTag)    { $ResourceTag    = "${productTag}:$envUpper" }
if (-not $AppDisplayName) { $AppDisplayName = "redmine-expert-helpdesk-$envLower" }
if (-not $RbacScopeName)  { $RbacScopeName  = "Redmine-expert-Helpdesk-Mailboxes-$envUpper" }

Write-Host "Removing the '$Environment' installation:" -ForegroundColor Cyan
Write-Host "  tag   $ResourceTag"
Write-Host "  app   $AppDisplayName"
Write-Host "  scope $RbacScopeName"
Write-Host ""

function Invoke-Confirmed {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object]$Details
    )

    Write-Host "`n--- $Description" -ForegroundColor Cyan
    if ($null -ne $Details) {
        # Out-String defaults to the console width and wraps long values, and
        # this is what the operator confirms a deletion against — so give it a
        # width that leaves scope names and filters intact.
        $Details | Format-List | Out-String -Width 4096 | Write-Host
    }

    if (-not $Force) {
        $answer = Read-Host "Delete this? [y/N]"
        if ($answer -notmatch '^(y|yes|j|ja)$') {
            Write-Host "Skipped." -ForegroundColor Yellow
            return
        }
    }

    & $Action
    Write-Host "Deleted." -ForegroundColor Green
}

# -----------------------------------------------------------------------
# Entra ID
# -----------------------------------------------------------------------
# Must run BEFORE Connect-ExchangeOnline: the EXO module loads an older
# Microsoft.Identity.Client, which afterwards breaks Connect-MgGraph
# ("Method not found: ...WithLogging").
Write-Host "== Entra ID ==" -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All"

# Deleting the application also removes its service principal.
# Single quotes delimit strings in an OData filter and are escaped by doubling
# them, so a name or tag containing an apostrophe stays findable here.
# The tag finds installations created under a different name; the display name
# stays the fallback for anything not stamped with it.
$tagLiteral = $ResourceTag -replace "'", "''"
try {
    $apps = @(Get-MgApplication -Filter "tags/any(t:t eq '$tagLiteral')" -All)
} catch {
    $apps = @(Get-MgApplication -All | Where-Object { @($_.Tags) -contains $ResourceTag })
}

if ($apps.Count -gt 0) {
    Write-Host "Found $($apps.Count) app registration(s) by tag '$ResourceTag'."
} else {
    $nameLiteral = $AppDisplayName -replace "'", "''"
    $apps = @(Get-MgApplication -Filter "DisplayName eq '$nameLiteral'")
}

if ($apps.Count -eq 0) {
    Write-Host "No app registration found by tag '$ResourceTag' or name '$AppDisplayName'."
}

# A tag should identify exactly one installation. Several means the tag was
# reused, and this script deletes things - so name them and refuse rather than
# work through them on an assumption.
if ($apps.Count -gt 1 -and -not $Force -and -not $PSBoundParameters.ContainsKey('AppDisplayName')) {
    throw ("Several app registrations carry the tag '$ResourceTag':`n" +
           (($apps | ForEach-Object { "  $($_.DisplayName)  (AppId $($_.AppId))" }) -join "`n") +
           "`nPass -AppDisplayName to name the one to remove, or -Force to remove all of them.")
}

# The later steps work off what was actually found, not off the parameter: an
# app located by tag can carry a completely different display name, and naming
# the parameter in a deletion prompt would describe the wrong object. Where
# nothing was found, the parameter remains the only lead - the app may already
# be gone from the directory while its soft-deleted copy and its Exchange
# objects are still there.
$targetNames = @($apps | ForEach-Object { $_.DisplayName } | Where-Object { $_ } | Sort-Object -Unique)
$targetAppIds = @($apps | ForEach-Object { $_.AppId } | Where-Object { $_ })
if ($targetNames.Count -eq 0) { $targetNames = @($AppDisplayName) }

foreach ($app in $apps) {
    $appObjectId = $app.Id
    Invoke-Confirmed `
        -Description "App registration '$($app.DisplayName)' (AppId $($app.AppId))" `
        -Details     ($app | Select-Object DisplayName, AppId, Id, Tags, CreatedDateTime) `
        -Action      { Remove-MgApplication -ApplicationId $appObjectId }
}

# Purge from the 30-day soft-delete bin so the name is truly free.
$deleted = @(Get-MgDirectoryDeletedItemAsApplication | Where-Object { $targetNames -contains $_.DisplayName })
if ($deleted.Count -eq 0) {
    Write-Host "Nothing to purge from the deleted items bin."
}
foreach ($item in $deleted) {
    $deletedId = $item.Id
    Invoke-Confirmed `
        -Description "PERMANENTLY purge soft-deleted app '$($item.DisplayName)' (AppId $($item.AppId))" `
        -Details     ($item | Select-Object DisplayName, AppId, Id, DeletedDateTime) `
        -Action      { Remove-MgDirectoryDeletedItem -DirectoryObjectId $deletedId }
}

# -----------------------------------------------------------------------
# Exchange Online
# -----------------------------------------------------------------------
Write-Host "`n== Exchange Online ==" -ForegroundColor Cyan
Connect-ExchangeOnline

# Get-ManagementRoleAssignment has no -CustomResourceScope filter, so filter client-side.
$roleAssignments = @(Get-ManagementRoleAssignment -ErrorAction SilentlyContinue |
    Where-Object { $_.CustomResourceScope -eq $RbacScopeName -or $targetNames -contains $_.RoleAssigneeName })
if ($roleAssignments.Count -eq 0) {
    Write-Host "No management role assignments on scope '$RbacScopeName'."
}
foreach ($ra in $roleAssignments) {
    $identity = $ra.Identity
    Invoke-Confirmed `
        -Description "Management role assignment '$identity'" `
        -Details     ($ra | Select-Object Identity, Role, RoleAssigneeName, CustomResourceScope) `
        -Action      { Remove-ManagementRoleAssignment -Identity $identity -Confirm:$false }
}

$scope = Get-ManagementScope -Identity $RbacScopeName -ErrorAction SilentlyContinue
if (-not $scope) {
    Write-Host "No management scope '$RbacScopeName'."
} else {
    Invoke-Confirmed `
        -Description "Management scope '$RbacScopeName'" `
        -Details     ($scope | Select-Object Name, RecipientFilter, ScopeRestrictionType) `
        -Action      { Remove-ManagementScope -Identity $RbacScopeName -Confirm:$false }
}

# AppId is what ties the Exchange object to the Entra app; the display names of
# the two need not agree, so it is the better match where we have it.
$exoSps = @(Get-ServicePrincipal | Where-Object {
    ($targetAppIds.Count -gt 0 -and $targetAppIds -contains $_.AppId) -or
    ($targetAppIds.Count -eq 0 -and $targetNames -contains $_.DisplayName) })
if ($exoSps.Count -eq 0) {
    Write-Host "No Exchange Online service principal for $($targetNames -join ', ')."
}
foreach ($exoSp in $exoSps) {
    $objectId = $exoSp.ObjectId
    Invoke-Confirmed `
        -Description "Exchange Online service principal '$($exoSp.DisplayName)' ($objectId)" `
        -Details     ($exoSp | Select-Object DisplayName, AppId, ObjectId) `
        -Action      { Remove-ServicePrincipal -Identity $objectId -Confirm:$false }
}

Write-Host "`nCleanup finished." -ForegroundColor Green
