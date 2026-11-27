#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Sets or adjusts today's cumulative unlocked time in state.json.
.DESCRIPTION
  Stops the LoginTimeLogger task briefly, rewrites UnlockedSecondsToday,
  appends a tagged line to today's unlocked-time-*.log, then starts the task:
    CUMULATIVE_RESET - set to 0
    CUMULATIVE_SET   - set to an absolute non-zero TIME
    CUMULATIVE_ADD   - add (+TIME)
    CUMULATIVE_DEC   - subtract (-TIME)

  Time argument forms (quote values that start with '-' so PowerShell does not
  treat them as parameters):
    (none)       set cumulative to 0
    TIME         set cumulative to TIME
    +TIME        add TIME to the current cumulative
    -TIME        subtract TIME from the current cumulative (floor at 0)

  TIME may be HH:MM:SS (hours may exceed 24) or a whole number of seconds.
.PARAMETER Time
  Absolute time, or signed delta (+TIME / -TIME). Empty = reset to 0.
.PARAMETER TaskName
  Scheduled task name (default LoginTimeLogger).
.PARAMETER ConfigPath
  Runtime config JSON. Default: path from the LoginTimeLogger task -ConfigPath
  argument, then %USERPROFILE%\LoginTimeLogger\config.json.
.PARAMETER LogDirectory
  Override log folder (default: from runtime config / Administrator profile).
.EXAMPLE
  .\scripts\Reset-CumulativeTime.ps1
.EXAMPLE
  .\scripts\Reset-CumulativeTime.ps1 01:30:00
.EXAMPLE
  .\scripts\Reset-CumulativeTime.ps1 +00:15:00
.EXAMPLE
  .\scripts\Reset-CumulativeTime.ps1 '-00:10:00'
.EXAMPLE
  .\scripts\Reset-CumulativeTime.ps1 +600
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [AllowEmptyString()]
    [string]$Time = '',

    [string]$TaskName = 'LoginTimeLogger',
    [string]$TemplateConfigPath,
    [string]$ConfigPath = '',
    [string]$LogDirectory = ''
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
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}
. $commonErrorPath

function ConvertFrom-CumulativeTimeText {
    <#
      Parses HH:MM:SS (hours may exceed 24) or a whole-second integer.
      Returns $null when invalid.
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $trimmed = $Text.Trim()
    if ($trimmed -match '^(?<h>\d+):(?<m>[0-5]?\d):(?<s>[0-5]?\d)$') {
        try {
            return [double](
                ([int]$Matches['h'] * 3600) +
                ([int]$Matches['m'] * 60) +
                [int]$Matches['s'])
        }
        catch {
            return $null
        }
    }
    if ($trimmed -match '^\d+$') {
        try {
            return [double][int]$trimmed
        }
        catch {
            return $null
        }
    }
    return $null
}

function Format-CumulativeDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Resolve-RuntimeConfigPath {
    param(
        [string]$ConfigPath,
        [string]$TaskName,
        [string]$AdministratorProfile
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "ConfigPath not found: '$ConfigPath'."
        }
        return $ConfigPath
    }

    $fromTask = Get-LoginTimeLoggerRuntimeConfigPath -TaskName $TaskName
    if ($fromTask) {
        return $fromTask
    }

    $guess = Join-Path $AdministratorProfile 'LoginTimeLogger\config.json'
    if (Test-Path -LiteralPath $guess) {
        return $guess
    }

    throw @"
Could not find the current runtime config.
Pass -ConfigPath to the installed file, for example:
  .\scripts\Reset-CumulativeTime.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
Or ensure scheduled task '$TaskName' exists with a -ConfigPath argument.
"@
}

function Start-LoginTimeLoggerTask {
    param([Parameter(Mandatory)][string]$Name)

    try {
        Start-ScheduledTask -TaskName $Name -ErrorAction Stop
        return
    }
    catch {
        $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $proc = Start-Process -FilePath $schtasks -ArgumentList @('/Run', '/TN', $Name) `
            -Wait -PassThru -WindowStyle Hidden
        if ($null -eq $proc -or $proc.ExitCode -ne 0) {
            $exit = if ($null -ne $proc) { $proc.ExitCode } else { '(null)' }
            throw ("Start-ScheduledTask and schtasks /Run both failed for '{0}' (schtasks exit={1})." -f $Name, $exit)
        }
    }
}

function Write-StateFileAtomic {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )

    $jsonText = ($State | ConvertTo-Json -Depth 4)
    $roundTrip = $jsonText | ConvertFrom-Json
    if ($null -eq $roundTrip -or $null -eq $roundTrip.PSObject.Properties['Date']) {
        throw (New-Object System.Exception('state.json JSON round-trip validation failed'))
    }

    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $tempPath = "$Path.tmp"
    Set-Content -LiteralPath $tempPath -Value $jsonText -Encoding UTF8
    $null = (Get-Content -LiteralPath $tempPath -Raw -Encoding UTF8) | ConvertFrom-Json
    try {
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
    }
    catch {
        if (Test-Path -LiteralPath $Path) {
            Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
        }
        Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
    }
}

try {
    $null = Initialize-ErrorLog -ConfigPath $TemplateConfigPath

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
            $tplAdmin = Get-OptionalPropertyValue -InputObject $template -Name 'AdministratorProfile'
            if (-not [string]::IsNullOrWhiteSpace([string]$tplAdmin)) {
                $administratorProfile = [string]$tplAdmin
            }
        }
        catch { }
    }

    $resolvedConfigPath = Resolve-RuntimeConfigPath `
        -ConfigPath $ConfigPath `
        -TaskName $TaskName `
        -AdministratorProfile $administratorProfile

    try {
        $null = Initialize-ErrorLog -ConfigPath $resolvedConfigPath
    }
    catch { }

    $unlockQuotaMinutes = 60
    $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    if (Test-Path -LiteralPath $resolvedConfigPath) {
        $raw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgAdmin = Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile'
        if (-not [string]::IsNullOrWhiteSpace([string]$cfgAdmin)) {
            $administratorProfile = [string]$cfgAdmin
        }
        $cfgLogDir = Get-OptionalPropertyValue -InputObject $raw -Name 'LogDirectory'
        if (-not [string]::IsNullOrWhiteSpace([string]$cfgLogDir)) {
            $logDirectory = [string]$cfgLogDir
        }
        else {
            $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
        }
        $cfgQuota = Get-OptionalPropertyValue -InputObject $raw -Name 'UnlockQuotaMinutes'
        if ($null -ne $cfgQuota) {
            try {
                $q = [int]$cfgQuota
                if ($q -ge 1) { $unlockQuotaMinutes = $q }
            }
            catch { }
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $logDirectory = $LogDirectory
    }

    $statePath = Join-Path $logDirectory 'state.json'
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $dailyLogPath = Join-Path $logDirectory ('unlocked-time-{0}.log' -f $today)

    $mode = 'set'
    $deltaSeconds = 0.0
    $trimmedTime = if ($null -eq $Time) { '' } else { $Time.Trim() }

    if ([string]::IsNullOrWhiteSpace($trimmedTime)) {
        $mode = 'set'
        $deltaSeconds = 0.0
        $targetOrDeltaLabel = '0 (reset)'
    }
    elseif ($trimmedTime.StartsWith('+')) {
        $mode = 'add'
        $parsed = ConvertFrom-CumulativeTimeText -Text $trimmedTime.Substring(1)
        if ($null -eq $parsed) {
            throw "Invalid +TIME value '$trimmedTime'. Use +HH:MM:SS or +seconds (e.g. +00:15:00 or +600)."
        }
        $deltaSeconds = [double]$parsed
        $targetOrDeltaLabel = ('+{0}' -f (Format-CumulativeDuration -Seconds $deltaSeconds))
    }
    elseif ($trimmedTime.StartsWith('-')) {
        $mode = 'subtract'
        $parsed = ConvertFrom-CumulativeTimeText -Text $trimmedTime.Substring(1)
        if ($null -eq $parsed) {
            throw "Invalid -TIME value '$trimmedTime'. Quote it so PowerShell does not treat it as a switch, e.g. '-00:10:00' or '-600'."
        }
        $deltaSeconds = [double]$parsed
        $targetOrDeltaLabel = ('-{0}' -f (Format-CumulativeDuration -Seconds $deltaSeconds))
    }
    else {
        $mode = 'set'
        $parsed = ConvertFrom-CumulativeTimeText -Text $trimmedTime
        if ($null -eq $parsed) {
            throw "Invalid TIME value '$trimmedTime'. Use HH:MM:SS or seconds (e.g. 01:30:00 or 5400)."
        }
        $deltaSeconds = [double]$parsed
        $targetOrDeltaLabel = Format-CumulativeDuration -Seconds $deltaSeconds
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    $wasRunning = $false
    if ($null -ne $task -and $task.State -eq 'Running') {
        $wasRunning = $true
        Write-Host ("Stopping '{0}'..." -f $TaskName)
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Reset-CumulativeTime' -Context (
                "Stop-ScheduledTask failed for '{0}'; continuing with state write" -f $TaskName)
        }
        Start-Sleep -Seconds 2
    }
    elseif ($null -eq $task) {
        Write-Host ("WARNING: scheduled task '{0}' not found; updating state.json only." -f $TaskName) `
            -ForegroundColor Yellow
    }

    $previousSeconds = 0.0
    $installedCommitSha = ''
    $lastUnlocked = $false
    $lastTransitionUtc = $null
    $forcedBreakDisabledDate = ''
    $forcedBreakRemainingSeconds = 0.0
    $pendingUnlockQuotaEnabled = $null
    $currentLockStartUtc = $null
    $lockIntervals = @()
    $pendingHibernateAfterSeconds = $null
    $pendingHibernateWarnShown = $false
    if (Test-Path -LiteralPath $statePath) {
        try {
            $existing = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $secRaw = Get-OptionalPropertyValue -InputObject $existing -Name 'UnlockedSecondsToday'
            if ($null -ne $secRaw) {
                try { $previousSeconds = [double]$secRaw } catch { $previousSeconds = 0.0 }
            }
            $installedCommitSha = [string](Get-OptionalPropertyValue -InputObject $existing -Name 'InstalledCommitSha')
            $lu = Get-OptionalPropertyValue -InputObject $existing -Name 'LastUnlocked'
            if ($null -ne $lu) {
                try { $lastUnlocked = [bool]$lu } catch { $lastUnlocked = $false }
            }
            $lastTransitionUtc = Get-OptionalPropertyValue -InputObject $existing -Name 'LastTransitionUtc'
            $forcedBreakDisabledDate = [string](Get-OptionalPropertyValue -InputObject $existing `
                    -Name 'ForcedBreakDisabledDate')
            if ($null -eq $forcedBreakDisabledDate) { $forcedBreakDisabledDate = '' }
            $breakRemainRaw = Get-OptionalPropertyValue -InputObject $existing `
                -Name 'ForcedBreakRemainingSeconds'
            if ($null -ne $breakRemainRaw) {
                try {
                    $forcedBreakRemainingSeconds = [double]$breakRemainRaw
                }
                catch { $forcedBreakRemainingSeconds = 0.0 }
            }
            $pendingUqRaw = Get-OptionalPropertyValue -InputObject $existing `
                -Name 'PendingUnlockQuotaEnabled'
            if ($null -ne $pendingUqRaw) {
                try { $pendingUnlockQuotaEnabled = [bool]$pendingUqRaw } catch {
                    $pendingUnlockQuotaEnabled = $null
                }
            }
            $lockStartRaw = Get-OptionalPropertyValue -InputObject $existing -Name 'CurrentLockStartUtc'
            if ($null -ne $lockStartRaw -and -not [string]::IsNullOrWhiteSpace([string]$lockStartRaw)) {
                $currentLockStartUtc = [string]$lockStartRaw
            }
            $intervalsRaw = Get-OptionalPropertyValue -InputObject $existing -Name 'LockIntervals'
            if ($null -ne $intervalsRaw) {
                $lockIntervals = @($intervalsRaw)
            }
            $pendingHibRaw = Get-OptionalPropertyValue -InputObject $existing `
                -Name 'PendingHibernateAfterSeconds'
            if ($null -ne $pendingHibRaw -and -not [string]::IsNullOrWhiteSpace([string]$pendingHibRaw)) {
                try {
                    $ph = [double]$pendingHibRaw
                    if ($ph -ge 0) { $pendingHibernateAfterSeconds = $ph }
                }
                catch { $pendingHibernateAfterSeconds = $null }
            }
            $hibWarnRaw = Get-OptionalPropertyValue -InputObject $existing `
                -Name 'PendingHibernateWarnShown'
            if ($null -ne $hibWarnRaw) {
                try { $pendingHibernateWarnShown = [bool]$hibWarnRaw } catch {
                    $pendingHibernateWarnShown = $false
                }
            }
        }
        catch {
            Write-Host ("WARNING: could not parse existing state.json; treating previous as 0. {0}" -f `
                    $_.Exception.Message) -ForegroundColor Yellow
        }
    }

    switch ($mode) {
        'add' { $newSeconds = $previousSeconds + $deltaSeconds }
        'subtract' { $newSeconds = $previousSeconds - $deltaSeconds }
        default { $newSeconds = $deltaSeconds }
    }
    if ($newSeconds -lt 0) {
        $newSeconds = 0.0
    }
    $newSeconds = [double][Math]::Floor($newSeconds)

    $quotaSeconds = [double]($unlockQuotaMinutes * 60)
    $newBucket = [int][Math]::Floor($newSeconds / $quotaSeconds)

    # Only adjust cumulative + quota bucket; keep break/lock-tracking fields intact.
    if ($lastUnlocked) {
        $currentLockStartUtc = $null
    }

    $newState = [pscustomobject]@{
        Date                        = $today
        UnlockedSecondsToday        = $newSeconds
        LastUnlocked                = [bool]$lastUnlocked
        LastTransitionUtc           = $(if ($null -ne $lastTransitionUtc -and
                -not [string]::IsNullOrWhiteSpace([string]$lastTransitionUtc)) {
                [string]$lastTransitionUtc
            }
            else { $null })
        LastUnlockQuotaBucket       = $newBucket
        InstalledCommitSha          = $(if ($null -eq $installedCommitSha) { '' } else { [string]$installedCommitSha })
        ForcedBreakDisabledDate     = [string]$forcedBreakDisabledDate
        ForcedBreakRemainingSeconds = [double]$forcedBreakRemainingSeconds
        PendingUnlockQuotaEnabled    = $pendingUnlockQuotaEnabled
        CurrentLockStartUtc          = $currentLockStartUtc
        LockIntervals                = @($lockIntervals)
        PendingHibernateAfterSeconds = $pendingHibernateAfterSeconds
        PendingHibernateWarnShown    = [bool]$pendingHibernateWarnShown
    }

    Write-StateFileAtomic -Path $statePath -State $newState

    $prevText = Format-CumulativeDuration -Seconds $previousSeconds
    $newText = Format-CumulativeDuration -Seconds $newSeconds
    $eventTag = switch ($mode) {
        'add' { 'CUMULATIVE_ADD' }
        'subtract' { 'CUMULATIVE_DEC' }
        default {
            if ($newSeconds -le 0) { 'CUMULATIVE_RESET' } else { 'CUMULATIVE_SET' }
        }
    }
    $nowLocal = Get-Date
    $adjustLine = ('{0:yyyy-MM-dd HH:mm:ss} | {1} | cumulative_today={2} | previous={3} | adjustment={4}' -f `
            $nowLocal, $eventTag, $newText, $prevText, $targetOrDeltaLabel)
    try {
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null
        }
        Add-Content -LiteralPath $dailyLogPath -Value $adjustLine -Encoding UTF8
    }
    catch {
        Write-Host ("WARNING: state updated but day-log append failed: {0}" -f $_.Exception.Message) `
            -ForegroundColor Yellow
    }

    Write-Host ("state.json: {0}" -f $statePath)
    Write-Host ("Previous cumulative: {0} ({1:F0}s)" -f $prevText, $previousSeconds)
    Write-Host ("Adjustment:          {0}" -f $targetOrDeltaLabel)
    Write-Host ("New cumulative:      {0} ({1:F0}s)" -f $newText, $newSeconds)

    if ($wasRunning -or ($null -ne $task)) {
        Write-Host ("Starting '{0}'..." -f $TaskName)
        Start-LoginTimeLoggerTask -Name $TaskName
        Start-Sleep -Seconds 1
        $taskAfter = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($null -ne $taskAfter) {
            Write-Host ("Task '{0}' state: {1}" -f $TaskName, $taskAfter.State)
            if ($taskAfter.State -ne 'Running') {
                Write-Host ("WARNING: task state is '{0}' (expected Running)." -f $taskAfter.State) `
                    -ForegroundColor Yellow
                exit 1
            }
        }
    }

    Write-Host 'Cumulative time updated.' -ForegroundColor Green
    exit 0
}
catch {
    $null = Write-FatalError -ErrorRecord $_ -Context 'Reset-CumulativeTime.ps1 failed' `
        -Source 'Reset-CumulativeTime'
    exit 1
}
