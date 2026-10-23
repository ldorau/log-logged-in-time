#Requires -Version 5.1
<#
.SYNOPSIS
  Lists interactive sessions and reports whether the configured target user is unlocked-active.
#>
[CmdletBinding()]
param(
    [string]$TemplateConfigPath,
    [string]$TargetUsername
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($TemplateConfigPath)) {
    $TemplateConfigPath = Join-Path $repoRoot 'config\config.json'
}

$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw @"
Test-Session failed: shared error helper missing.
Expected: $commonErrorPath
ScriptDir: $scriptDir
"@
}
. $commonErrorPath
$null = Initialize-ErrorLog -ConfigPath $TemplateConfigPath
Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

try {
    if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
        $administratorProfile = Join-Path $env:SystemDrive 'Users\Administrator'
        if (Test-Path -LiteralPath $TemplateConfigPath) {
            try {
                $template = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$template.AdministratorProfile)) {
                    $administratorProfile = [string]$template.AdministratorProfile
                }
            }
            catch {
                $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                    "Failed to parse template config '{0}'" -f $TemplateConfigPath)
                throw (New-Object System.Exception($details, $_.Exception))
            }
        }

        $runtimeConfigPath = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
        $configPath = if (Test-Path -LiteralPath $runtimeConfigPath) { $runtimeConfigPath } else { $TemplateConfigPath }

        if (-not (Test-Path -LiteralPath $configPath)) {
            throw @"
Config file not found.
Tried runtime: $runtimeConfigPath
Tried template: $TemplateConfigPath
AdministratorProfile: $administratorProfile
"@
        }

        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Failed to parse config '{0}'" -f $configPath)
            throw (New-Object System.Exception($details, $_.Exception))
        }

        $TargetUsername = [string]$raw.TargetUsername
        if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
            throw @"
TargetUsername is empty in config.
Config path: $configPath
Set the Windows logon name in TargetUsername, then retry.
"@
        }
        Write-Host "Using config: $configPath"
    }

    $csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
    if (-not (Test-Path -LiteralPath $csPath)) {
        throw "SessionQuery.cs not found at '$csPath'."
    }

    try {
        if (-not ('SessionQuery' -as [type])) {
            $src = Get-Content -LiteralPath $csPath -Raw -Encoding UTF8
            Add-Type -TypeDefinition $src -Language CSharp -ErrorAction Stop
        }
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Add-Type failed for '{0}'" -f $csPath)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    try {
        $sessions = [SessionQuery]::GetSessions()
        $sessions | Format-Table SessionId, UserName, DomainName, State, IsLocked, IsActive, IsUnlockedActive -AutoSize
        $unlocked = [SessionQuery]::IsUserUnlocked($TargetUsername)
        Write-Host ('IsUserUnlocked({0}) = {1}' -f $TargetUsername, $unlocked)
        if (-not [string]::IsNullOrWhiteSpace([SessionQuery]::LastError)) {
            Write-Host ("SessionQuery.LastError: {0}" -f [SessionQuery]::LastError) -ForegroundColor Yellow
        }
    }
    catch {
        $last = $null
        try { $last = [SessionQuery]::LastError } catch { $last = '(unavailable)' }
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Session enumeration failed; target='{0}'; SessionQuery.LastError='{1}'" -f $TargetUsername, $last)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Test-Session.ps1 failed' -Source 'Test-Session'
    throw
}
