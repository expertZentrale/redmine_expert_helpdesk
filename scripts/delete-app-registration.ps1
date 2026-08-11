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

.PARAMETER AppDisplayName
    Display name of the app registration / service principal to remove.

.PARAMETER RbacScopeName
    Name of the Exchange Online management scope to remove.

.PARAMETER Force
    Skip all confirmation prompts.

.EXAMPLE
    ./delete-app-registration.ps1
#>

[CmdletBinding()]
param(
    [string]$AppDisplayName = "redmine-expert-helpdesk-live",

    [string]$RbacScopeName = "Redmine-expert-Helpdesk-Mailboxes-LIVE",

    [switch]$Force
)

$ErrorActionPreference = "Stop"

function Invoke-Confirmed {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action,
        [object]$Details
    )

    Write-Host "`n--- $Description" -ForegroundColor Cyan
    if ($null -ne $Details) {
        $Details | Format-List | Out-String | Write-Host
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
$apps = @(Get-MgApplication -Filter "DisplayName eq '$AppDisplayName'")
if ($apps.Count -eq 0) {
    Write-Host "No app registration named '$AppDisplayName'."
}
foreach ($app in $apps) {
    $appObjectId = $app.Id
    Invoke-Confirmed `
        -Description "App registration '$AppDisplayName' (AppId $($app.AppId))" `
        -Details     ($app | Select-Object DisplayName, AppId, Id, CreatedDateTime) `
        -Action      { Remove-MgApplication -ApplicationId $appObjectId }
}

# Purge from the 30-day soft-delete bin so the name is truly free.
$deleted = @(Get-MgDirectoryDeletedItemAsApplication | Where-Object DisplayName -eq $AppDisplayName)
if ($deleted.Count -eq 0) {
    Write-Host "Nothing to purge from the deleted items bin."
}
foreach ($item in $deleted) {
    $deletedId = $item.Id
    Invoke-Confirmed `
        -Description "PERMANENTLY purge soft-deleted app '$AppDisplayName' (AppId $($item.AppId))" `
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
    Where-Object { $_.CustomResourceScope -eq $RbacScopeName -or $_.RoleAssigneeName -eq $AppDisplayName })
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

$exoSps = @(Get-ServicePrincipal | Where-Object DisplayName -eq $AppDisplayName)
if ($exoSps.Count -eq 0) {
    Write-Host "No Exchange Online service principal named '$AppDisplayName'."
}
foreach ($exoSp in $exoSps) {
    $objectId = $exoSp.ObjectId
    Invoke-Confirmed `
        -Description "Exchange Online service principal '$AppDisplayName' ($objectId)" `
        -Details     ($exoSp | Select-Object DisplayName, AppId, ObjectId) `
        -Action      { Remove-ServicePrincipal -Identity $objectId -Confirm:$false }
}

Write-Host "`nCleanup finished." -ForegroundColor Green
