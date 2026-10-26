#Requires -Version 5.1
<#
.SYNOPSIS
  Estimates locked/away time from existing unlocked-time daily logs.
.DESCRIPTION
  Reads LOCKED_OR_AWAY / UNLOCKED_ACTIVE transitions in
  unlocked-time-YYYY-MM-DD.log and sums intervals between them.
  Does not change monitor behavior or other scripts. LOCKED_OR_AWAY means
  not unlocked-active (screen lock or away / no active session).
.PARAMETER Date
  Calendar day to analyze (local). Default: today.
.PARAMETER AllDays
  Analyze every unlocked-time-*.log in the log directory.
.PARAMETER LogDirectory
  Override log folder (default: from runtime config / Administrator profile).
.PARAMETER LogPath
  Analyze a single log file path (ignores -Date / -AllDays).
.EXAMPLE
  .\scripts\Get-LockedTime.ps1
.EXAMPLE
  .\scripts\Get-LockedTime.ps1 -Date 2026-10-26
.EXAMPLE
  .\scripts\Get-LockedTime.ps1 -AllDays
#>
[CmdletBinding(DefaultParameterSetName = 'ByDate')]
param(
    [Parameter(ParameterSetName = 'ByDate')]
    [datetime]$Date = (Get-Date).Date,

    [Parameter(ParameterSetName = 'AllDays')]
    [switch]$AllDays,

    [string]$LogDirectory,

    [Parameter(ParameterSetName = 'ByPath')]
    [string]$LogPath,

    [string]$TemplateConfigPath
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
Get-LockedTime failed: shared error helper missing.
Expected: $commonErrorPath
ScriptDir: $scriptDir
"@
}
. $commonErrorPath
$null = Initialize-ErrorLog -ConfigPath $TemplateConfigPath

function Get-DefaultLogDirectory {
    param([string]$TemplateConfigPath)

    $administratorProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        $env:USERPROFILE
    }
    else {
        Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
    }

    if (Test-Path -LiteralPath $TemplateConfigPath) {
        try {
            $template = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$template.AdministratorProfile)) {
                $administratorProfile = [string]$template.AdministratorProfile
            }
        }
        catch { }
    }

    $runtimeConfigPath = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
    $configPath = if (Test-Path -LiteralPath $runtimeConfigPath) { $runtimeConfigPath } else { $TemplateConfigPath }
    if (Test-Path -LiteralPath $configPath) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
                $administratorProfile = [string]$raw.AdministratorProfile
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
                return [string]$raw.LogDirectory
            }
        }
        catch { }
    }

    return (Join-Path $administratorProfile 'LoginTimeLogs')
}

function Format-DurationText {
    param([TimeSpan]$Value)
    if ($Value.TotalHours -ge 1) {
        return '{0:00}:{1:00}:{2:00} ({3:F2}h)' -f `
            [int][Math]::Floor($Value.TotalHours), $Value.Minutes, $Value.Seconds, $Value.TotalHours
    }
    return '{0:00}:{1:00}:{2:00}' -f `
        [int][Math]::Floor($Value.TotalHours), $Value.Minutes, $Value.Seconds
}

function Get-LockedIntervalsFromLog {
    param(
        [Parameter(Mandatory)][string]$Path,
        [datetime]$AsOf = (Get-Date)
    )

    # Use ArrayList: Generic List[T].Add often hits "Argument types do not match" in Windows PowerShell 5.1.
    $intervals = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            LogPath           = $Path
            Exists            = $false
            TransitionCount   = 0
            Intervals         = @()
            TotalLocked       = [TimeSpan]::Zero
            OpenLockStart     = $null
            Notes             = @('Log file not found.')
        }
    }

    $lines = @(Get-Content -LiteralPath $Path -ErrorAction Stop)
    $lockStart = $null
    $transitionCount = 0
    $notes = New-Object System.Collections.ArrayList

    foreach ($line in $lines) {
        if ($line -notmatch '^\s*(?<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s*\|\s*(?<event>LOCKED_OR_AWAY|UNLOCKED_ACTIVE)\b') {
            continue
        }
        $transitionCount++
        $ts = [datetime]::ParseExact($Matches['ts'], 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $eventName = $Matches['event']

        if ($eventName -eq 'LOCKED_OR_AWAY') {
            if ($null -ne $lockStart) {
                $null = $notes.Add(("Overlapping LOCKED_OR_AWAY at {0:yyyy-MM-dd HH:mm:ss}; previous open interval closed at this timestamp." -f $ts))
                $null = $intervals.Add([pscustomobject]@{
                        Start    = $lockStart
                        End      = $ts
                        Duration = ($ts - $lockStart)
                        Open     = $false
                    })
            }
            $lockStart = $ts
        }
        elseif ($eventName -eq 'UNLOCKED_ACTIVE') {
            if ($null -eq $lockStart) {
                # Unlock without a prior lock in this file (e.g. monitor started unlocked).
                continue
            }
            $null = $intervals.Add([pscustomobject]@{
                    Start    = $lockStart
                    End      = $ts
                    Duration = ($ts - $lockStart)
                    Open     = $false
                })
            $lockStart = $null
        }
    }

    $openLockStart = $null
    if ($null -ne $lockStart) {
        $openLockStart = $lockStart
        $null = $intervals.Add([pscustomobject]@{
                Start    = $lockStart
                End      = $AsOf
                Duration = ($AsOf - $lockStart)
                Open     = $true
            })
        $null = $notes.Add(("Still locked/away since {0:yyyy-MM-dd HH:mm:ss}; open interval ends at {1:yyyy-MM-dd HH:mm:ss}." -f $lockStart, $AsOf))
    }

    $total = [TimeSpan]::Zero
    foreach ($i in $intervals) {
        $total += $i.Duration
    }

    if ($transitionCount -eq 0) {
        $null = $notes.Add('No LOCKED_OR_AWAY / UNLOCKED_ACTIVE transitions in this log.')
    }
    elseif ($intervals.Count -eq 0) {
        $null = $notes.Add('No completed lock/away intervals (e.g. unlock-only start with no LOCKED_OR_AWAY yet).')
    }

    return [pscustomobject]@{
        LogPath         = $Path
        Exists          = $true
        TransitionCount = $transitionCount
        Intervals       = @($intervals.ToArray())
        TotalLocked     = $total
        OpenLockStart   = $openLockStart
        Notes           = @($notes.ToArray())
    }
}

try {
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))
    Write-Host 'Note: LOCKED_OR_AWAY = not unlocked-active (lock or away). Estimate from log transitions only.' -ForegroundColor DarkGray
    Write-Host ''

    $logFiles = New-Object System.Collections.ArrayList

    if ($PSCmdlet.ParameterSetName -eq 'ByPath') {
        if ([string]::IsNullOrWhiteSpace($LogPath)) {
            throw 'LogPath is empty.'
        }
        $null = $logFiles.Add($LogPath)
    }
    else {
        if ([string]::IsNullOrWhiteSpace($LogDirectory)) {
            $LogDirectory = Get-DefaultLogDirectory -TemplateConfigPath $TemplateConfigPath
        }
        Write-Host ("Log directory: {0}" -f $LogDirectory)

        if ($AllDays) {
            if (-not (Test-Path -LiteralPath $LogDirectory)) {
                throw "Log directory not found: $LogDirectory"
            }
            $found = @(Get-ChildItem -LiteralPath $LogDirectory -Filter 'unlocked-time-*.log' -File -ErrorAction SilentlyContinue |
                Sort-Object Name)
            if ($found.Count -eq 0) {
                throw "No unlocked-time-*.log files under $LogDirectory"
            }
            foreach ($f in $found) {
                $null = $logFiles.Add($f.FullName)
            }
        }
        else {
            $day = $Date.Date
            $null = $logFiles.Add((Join-Path $LogDirectory ('unlocked-time-{0:yyyy-MM-dd}.log' -f $day)))
        }
    }

    $grandTotal = [TimeSpan]::Zero
    $anyExists = $false

    foreach ($path in $logFiles) {
        $result = Get-LockedIntervalsFromLog -Path $path
        Write-Host ("=== {0} ===" -f $path)
        if (-not $result.Exists) {
            Write-Host '  (file not found)'
            Write-Host ''
            continue
        }
        $anyExists = $true
        Write-Host ("  Transitions: {0}" -f $result.TransitionCount)
        Write-Host ("  Locked/away total: {0}" -f (Format-DurationText -Value $result.TotalLocked))

        if ($result.Intervals.Count -gt 0) {
            Write-Host '  Intervals:'
            foreach ($interval in $result.Intervals) {
                $openTag = if ($interval.Open) { ' (open)' } else { '' }
                Write-Host ("    {0:yyyy-MM-dd HH:mm:ss} -> {1:yyyy-MM-dd HH:mm:ss}  {2}{3}" -f `
                        $interval.Start, $interval.End, (Format-DurationText -Value $interval.Duration), $openTag)
            }
        }
        else {
            Write-Host '  Intervals: (none)'
        }

        foreach ($note in $result.Notes) {
            Write-Host ("  Note: {0}" -f $note) -ForegroundColor DarkGray
        }
        Write-Host ''
        $grandTotal += $result.TotalLocked
    }

    if ($logFiles.Count -gt 1 -and $anyExists) {
        Write-Host ("Grand total locked/away: {0}" -f (Format-DurationText -Value $grandTotal)) -ForegroundColor Cyan
    }

    if (-not $anyExists) {
        throw "No log files found to analyze."
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Get-LockedTime.ps1 failed' -Source 'Get-LockedTime'
    throw
}
