#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Stops and removes the LoginTimeLogger scheduled task and installed files.
  Administrator-profile config is removed. Log files are kept unless -RemoveLogs.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'LoginTimeLogger',
    [string]$AdministratorProfile = (Join-Path $env:SystemDrive 'Users\Administrator'),
    [string]$TemplateConfigPath,
    [switch]$RemoveLogs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
if ([string]::IsNullOrWhiteSpace($TemplateConfigPath)) {
    $TemplateConfigPath = Join-Path $repoRoot 'config\config.json'
}
$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (Test-Path -LiteralPath $commonErrorPath) {
    . $commonErrorPath
}
else {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}

try {
    $null = Initialize-ErrorLog -AdministratorProfile $AdministratorProfile -ConfigPath $TemplateConfigPath
    if (Test-Path -LiteralPath $TemplateConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
                $AdministratorProfile = [string]$raw.AdministratorProfile
                $null = Initialize-ErrorLog -AdministratorProfile $AdministratorProfile
            }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Uninstall' -Context (
                "Could not parse template config '{0}'; continuing with AdministratorProfile='{1}'" -f `
                    $TemplateConfigPath, $AdministratorProfile)
        }
    }
    else {
        $null = Write-ErrorMessage -Level WARN -Source 'Uninstall' -Message (
            "Template config not found at '$TemplateConfigPath'. Using AdministratorProfile='$AdministratorProfile'.")
    }
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        try {
            if ($task.State -eq 'Running') {
                Write-Host ("Stopping running task '{0}' (State={1})..." -f $TaskName, $task.State)
                Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
                Start-Sleep -Seconds 2
            }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Uninstall' -Context (
                "Stop-ScheduledTask failed; task='{0}'; state='{1}'. Will still try Unregister-ScheduledTask." -f `
                    $TaskName, $task.State)
        }

        try {
            Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false -ErrorAction Stop
            Write-Host "Removed scheduled task '$TaskName'."
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "Unregister-ScheduledTask failed; task='{0}'" -f $TaskName)
            throw (New-Object System.Exception($details, $_.Exception))
        }
    }
    else {
        Write-Host "Scheduled task '$TaskName' was not found."
    }

    $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    if (Test-Path -LiteralPath $installRoot) {
        try {
            Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction Stop
            Write-Host "Removed install directory: $installRoot"
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "Failed to remove Program Files install directory '{0}'" -f $installRoot)
            throw (New-Object System.Exception($details, $_.Exception))
        }
    }
    else {
        Write-Host "Install directory not present: $installRoot"
    }

    $adminAppDirectory = Join-Path $AdministratorProfile 'LoginTimeLogger'
    if (Test-Path -LiteralPath $adminAppDirectory) {
        try {
            Remove-Item -LiteralPath $adminAppDirectory -Recurse -Force -ErrorAction Stop
            Write-Host "Removed Administrator config directory: $adminAppDirectory"
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "Failed to remove Administrator config directory '{0}'" -f $adminAppDirectory)
            throw (New-Object System.Exception($details, $_.Exception))
        }
    }
    else {
        Write-Host "Administrator config directory not present: $adminAppDirectory"
    }

    if ($RemoveLogs) {
        $logDirectory = Join-Path $AdministratorProfile 'LoginTimeLogs'
        if (Test-Path -LiteralPath $TemplateConfigPath) {
            try {
                $raw = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
                if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
                    $logDirectory = [string]$raw.LogDirectory
                }
            }
            catch {
                $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Uninstall' -Context (
                    "Could not read LogDirectory from '{0}'; using default '{1}'" -f `
                        $TemplateConfigPath, $logDirectory)
            }
        }

        if (Test-Path -LiteralPath $logDirectory) {
            try {
                Remove-Item -LiteralPath $logDirectory -Recurse -Force -ErrorAction Stop
                Write-Host "Removed log directory: $logDirectory"
            }
            catch {
                $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                    "Failed to remove log directory '{0}'" -f $logDirectory)
                throw (New-Object System.Exception($details, $_.Exception))
            }
        }
        else {
            Write-Host "Log directory not present: $logDirectory"
        }
    }
    else {
        Write-Host 'Log files were kept. Pass -RemoveLogs to delete them.'
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Uninstall.ps1 failed' -Source 'Uninstall'
    throw
}
