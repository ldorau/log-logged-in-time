#Requires -Version 5.1
<#
.SYNOPSIS
  Debug unlocked-time cumulative jumps (heartbeat credit vs wall clock).
.DESCRIPTION
  Investigates cases where day-log cumulative_today appears to jump
  (e.g. 00:27:45 -> 01:42:48). Root cause previously found: Format-Duration
  used [int]$ts.TotalHours and PowerShell rounds doubles, so after ~30 minutes
  the hour field became 01 while minutes stayed correct (display-only; state
  seconds were fine). Lock detection is out of scope.

  Modes:
    Analyze (default) - parse a day log + state.json; flag anomalous jumps;
                        compare Format-Duration variants; estimate expected time.
    Watch             - sample state.json on an interval while you stay unlocked.
    SelfTest          - unit-check Format-Duration + a capped credit-loop simulation.
.PARAMETER Date
  Day log date (local). Default: today.
.PARAMETER LogDirectory
  Override log folder (default: runtime config / profile LoginTimeLogs).
.PARAMETER LogPath
  Analyze one specific unlocked-time-*.log file.
.PARAMETER Watch
  Live-sample state.json.
.PARAMETER WatchSeconds
  How long to watch (default 1200 = 20 minutes).
.PARAMETER SampleIntervalSeconds
  Watch sample interval (default 10).
.PARAMETER SelfTest
  Run Format-Duration / credit-loop checks only.
.PARAMETER JumpRatioThreshold
  Flag a jump when cumulative gain / wall-clock gain exceeds this (default 1.5)
  and wall-clock gap is at least MinGapSeconds.
.PARAMETER MinGapSeconds
  Minimum wall-clock gap between two cumulative samples before jump check (default 60).
.EXAMPLE
  .\scripts\Test-UnlockedCumulative.ps1
.EXAMPLE
  .\scripts\Test-UnlockedCumulative.ps1 -Date 2026-10-27
.EXAMPLE
  .\scripts\Test-UnlockedCumulative.ps1 -Watch -WatchSeconds 900
.EXAMPLE
  .\scripts\Test-UnlockedCumulative.ps1 -SelfTest
#>
[CmdletBinding(DefaultParameterSetName = 'Analyze')]
param(
    [Parameter(ParameterSetName = 'Analyze')]
    [datetime]$Date = (Get-Date).Date,

    [Parameter(ParameterSetName = 'Analyze')]
    [Parameter(ParameterSetName = 'Watch')]
    [string]$LogDirectory = '',

    [Parameter(ParameterSetName = 'Analyze')]
    [string]$LogPath = '',

    [Parameter(ParameterSetName = 'Watch')]
    [switch]$Watch,

    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(30, 86400)]
    [int]$WatchSeconds = 1200,

    [Parameter(ParameterSetName = 'Watch')]
    [ValidateRange(2, 300)]
    [int]$SampleIntervalSeconds = 10,

    [Parameter(ParameterSetName = 'SelfTest')]
    [switch]$SelfTest,

    [ValidateRange(1.05, 100)]
    [double]$JumpRatioThreshold = 1.5,

    [ValidateRange(1, 3600)]
    [int]$MinGapSeconds = 60,

    [string]$TemplateConfigPath = ''
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
$null = Initialize-ErrorLog -ConfigPath $TemplateConfigPath

function Write-TestLine {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'PASS', 'FAIL', 'WARN')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    switch ($Level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

function Get-ResolvedLogDirectory {
    param([string]$Override, [string]$TemplateConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override.Trim()
    }

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
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.PollIntervalSeconds)) {
                # returned via side channel below if needed
            }
        }
        catch { }
    }

    return (Join-Path $administratorProfile 'LoginTimeLogs')
}

function Get-RuntimePollIntervalSeconds {
    param([string]$LogDirectory, [string]$TemplateConfigPath)

    $candidates = New-Object System.Collections.ArrayList
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $adminHome = Split-Path -Parent $LogDirectory
        $null = $candidates.Add((Join-Path $adminHome 'LoginTimeLogger\config.json'))
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        $null = $candidates.Add((Join-Path $env:USERPROFILE 'LoginTimeLogger\config.json'))
    }
    if (-not [string]::IsNullOrWhiteSpace($TemplateConfigPath)) {
        $null = $candidates.Add($TemplateConfigPath)
    }

    foreach ($path in $candidates) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        try {
            $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($null -ne $raw.PollIntervalSeconds -and [int]$raw.PollIntervalSeconds -gt 0) {
                return [int]$raw.PollIntervalSeconds
            }
        }
        catch { }
    }
    return 5
}

# Current/correct LoginTimeLogger formula (Floor). Keep in sync with src\LoginTimeLogger.ps1.
function Format-Duration-MonitorStyle {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

# Buggy historical formula: PowerShell [int] cast rounds doubles (0.5+ -> 1).
function Format-Duration-BuggyRoundedTotalHours {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    '{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
}

function Format-Duration-HoursProperty {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    '{0:00}:{1:00}:{2:00}' -f $ts.Hours, $ts.Minutes, $ts.Seconds
}

function ConvertFrom-DurationText {
    param([Parameter(Mandatory)][string]$Text)
    if ($Text -notmatch '^(?<h>\d+):(?<m>\d{2}):(?<s>\d{2})$') {
        return $null
    }
    return (3600 * [int]$Matches['h']) + (60 * [int]$Matches['m']) + [int]$Matches['s']
}

function Get-CumulativeSamplesFromLog {
    param([Parameter(Mandatory)][string]$Path)

    $samples = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    foreach ($line in @(Get-Content -LiteralPath $Path -ErrorAction Stop)) {
        if ($line -notmatch '^\s*(?<ts>\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2})\s*\|\s*(?<event>[A-Z_]+)\b') {
            continue
        }
        # Save before further -match calls overwrite $Matches.
        $tsText = $Matches['ts']
        $eventName = $Matches['event']
        if ($eventName -notin @('HEARTBEAT', 'UNLOCKED_ACTIVE', 'LOCKED_OR_AWAY')) {
            continue
        }
        if ($line -notmatch 'cumulative_today=(?<dur>\d+:\d{2}:\d{2})') {
            continue
        }
        $durText = $Matches['dur']
        $secs = ConvertFrom-DurationText -Text $durText
        if ($null -eq $secs) { continue }

        $unlocked = $null
        if ($eventName -eq 'HEARTBEAT') {
            if ($line -match 'unlocked=(True|False)') {
                $unlocked = ($Matches[1] -eq 'True')
            }
        }
        elseif ($eventName -eq 'UNLOCKED_ACTIVE') {
            $unlocked = $true
        }
        elseif ($eventName -eq 'LOCKED_OR_AWAY') {
            $unlocked = $false
        }

        $ts = [datetime]::ParseExact($tsText, 'yyyy-MM-dd HH:mm:ss', [System.Globalization.CultureInfo]::InvariantCulture)
        $null = $samples.Add([pscustomobject]@{
                TimestampLocal     = $ts
                Event              = $eventName
                Unlocked           = $unlocked
                CumulativeText     = $durText
                CumulativeSeconds  = [int]$secs
                RawLine            = $line
            })
    }

    return @($samples)
}

function Test-FormatDurationSelfTest {
    $cases = @(
        @{ Sec = 0; Expect = '00:00:00' }
        @{ Sec = 5; Expect = '00:00:05' }
        @{ Sec = 1665; Expect = '00:27:45' }   # observed pre-jump
        @{ Sec = 1800; Expect = '00:30:00' }   # exactly 0.5h - rounding trap
        @{ Sec = 2100; Expect = '00:35:00' }   # >0.5h must stay 00: not 01:
        @{ Sec = 3577; Expect = '00:59:37' }   # ~state.json after long run
        @{ Sec = 3600; Expect = '01:00:00' }
        @{ Sec = 6168; Expect = '01:42:48' }
        @{ Sec = 7154; Expect = '01:59:14' }
    )
    $failed = 0
    foreach ($c in $cases) {
        $got = Format-Duration-MonitorStyle -Seconds $c.Sec
        $buggy = Format-Duration-BuggyRoundedTotalHours -Seconds $c.Sec
        $alt = Format-Duration-HoursProperty -Seconds $c.Sec
        if ($got -ne $c.Expect) {
            Write-TestLine -Level FAIL -Message ("Format-Duration-MonitorStyle({0}) got {1}, expected {2}" -f $c.Sec, $got, $c.Expect)
            $failed++
        }
        else {
            Write-TestLine -Level PASS -Message ("Format-Duration-MonitorStyle({0}) = {1}" -f $c.Sec, $got)
        }
        if ($alt -ne $got -and $c.Sec -lt 86400) {
            Write-TestLine -Level WARN -Message ("Hours vs Floor(TotalHours) differ at {0}s: Hours={1} Floor={2}" -f $c.Sec, $alt, $got)
        }
        # Document the historical bug fingerprint around >= 30 minutes.
        if ($c.Sec -ge 1800 -and $c.Sec -lt 3600 -and $buggy -ne $got) {
            Write-TestLine -Level INFO -Message (
                "Buggy [int]TotalHours({0}s) would display {1} (rounded hour); fixed display is {2}." -f `
                    $c.Sec, $buggy, $got)
        }
    }

    # Explicit regression: PowerShell [int] 0.99 => 1 (rounding), Floor => 0.
    $rounded = [int]0.99
    $floored = [int][Math]::Floor(0.99)
    if ($rounded -ne 1 -or $floored -ne 0) {
        Write-TestLine -Level FAIL -Message ("Expected PowerShell [int]0.99=1 and Floor=0; got round={0} floor={1}" -f $rounded, $floored)
        $failed++
    }
    else {
        Write-TestLine -Level PASS -Message 'Confirmed PowerShell [int] cast rounds 0.99 -> 1 (root cause of hour jump).'
    }
    return ($failed -eq 0)
}

function Test-CreditLoopSelfTest {
    param([int]$PollIntervalSeconds = 5, [int]$WallSeconds = 900)

    $maxCredit = [Math]::Max($PollIntervalSeconds * 2, 15)
    $unlockedSeconds = 0.0
    $lastPollUtc = [datetime]::UtcNow
    $end = $lastPollUtc.AddSeconds($WallSeconds)
    # Simulate ideal polls every PollIntervalSeconds with no hangs.
    $simulatedNow = $lastPollUtc
    while ($simulatedNow -lt $end) {
        $simulatedNow = $simulatedNow.AddSeconds($PollIntervalSeconds)
        $elapsed = ($simulatedNow - $lastPollUtc).TotalSeconds
        if ($elapsed -gt $maxCredit) {
            $elapsed = $PollIntervalSeconds
        }
        if ($elapsed -lt 0) { $elapsed = 0 }
        $unlockedSeconds += $elapsed
        $lastPollUtc = $simulatedNow
    }

    $ratio = if ($WallSeconds -gt 0) { $unlockedSeconds / $WallSeconds } else { 0 }
    Write-TestLine -Level INFO -Message (
        "Credit-loop sim: poll={0}s wall={1}s credited={2:F1}s ratio={3:F3} maxCredit={4}s" -f `
            $PollIntervalSeconds, $WallSeconds, $unlockedSeconds, $ratio, $maxCredit)
    if ($ratio -gt 1.05 -or $ratio -lt 0.85) {
        Write-TestLine -Level FAIL -Message 'Ideal credit loop should stay near 1.0x wall clock.'
        return $false
    }
    Write-TestLine -Level PASS -Message 'Ideal capped credit loop stays near wall clock.'
    return $true
}

function Invoke-AnalyzeMode {
    param(
        [string]$Path,
        [string]$StatePath,
        [int]$PollIntervalSeconds,
        [double]$JumpRatioThreshold,
        [int]$MinGapSeconds
    )

    Write-Host ''
    Write-Host '=== Unlocked cumulative analyzer ===' -ForegroundColor Cyan
    Write-Host ("Log:   {0}" -f $Path)
    Write-Host ("State: {0}" -f $(if ($StatePath) { $StatePath } else { '(none)' }))
    Write-Host ("PollIntervalSeconds (config): {0}" -f $PollIntervalSeconds)
    Write-Host ("Jump flag when cumulative/wall > {0} and wall gap >= {1}s" -f $JumpRatioThreshold, $MinGapSeconds)
    Write-Host ''

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-TestLine -Level FAIL -Message "Day log not found: $Path"
        return 1
    }

    $samples = @(Get-CumulativeSamplesFromLog -Path $Path)
    if ($samples.Count -eq 0) {
        Write-TestLine -Level FAIL -Message 'No cumulative_today samples found in log.'
        return 1
    }

    Write-TestLine -Level INFO -Message ("Parsed {0} cumulative samples." -f $samples.Count)

    $jumps = New-Object System.Collections.ArrayList
    $frozenOk = New-Object System.Collections.ArrayList
    for ($i = 1; $i -lt $samples.Count; $i++) {
        $prev = $samples[$i - 1]
        $cur = $samples[$i]
        $wall = ($cur.TimestampLocal - $prev.TimestampLocal).TotalSeconds
        $delta = $cur.CumulativeSeconds - $prev.CumulativeSeconds

        if ($wall -lt 0) {
            Write-TestLine -Level WARN -Message ("Time went backwards between samples at {0:HH:mm:ss}." -f $cur.TimestampLocal)
            continue
        }

        # While locked, cumulative should not rise.
        if ($cur.Unlocked -eq $false -and $prev.Unlocked -eq $false -and $delta -eq 0 -and $wall -ge $MinGapSeconds) {
            $null = $frozenOk.Add([pscustomobject]@{
                    From = $prev.TimestampLocal
                    To   = $cur.TimestampLocal
                    Wall = [int]$wall
                })
        }

        if ($wall -lt $MinGapSeconds) { continue }
        if ($delta -le 0) { continue }

        $ratio = $delta / [Math]::Max($wall, 0.001)
        if ($ratio -gt $JumpRatioThreshold) {
            $null = $jumps.Add([pscustomobject]@{
                    FromText = $prev.CumulativeText
                    ToText   = $cur.CumulativeText
                    FromSec  = $prev.CumulativeSeconds
                    ToSec    = $cur.CumulativeSeconds
                    DeltaSec = $delta
                    WallSec  = [int]$wall
                    Ratio    = [Math]::Round($ratio, 2)
                    FromTs   = $prev.TimestampLocal
                    ToTs     = $cur.TimestampLocal
                    FromEv   = $prev.Event
                    ToEv     = $cur.Event
                    Unlocked = $cur.Unlocked
                })
        }
    }

    if ($frozenOk.Count -gt 0) {
        Write-TestLine -Level PASS -Message ("Locked windows with frozen cumulative: {0}" -f $frozenOk.Count)
    }

    if ($jumps.Count -eq 0) {
        Write-TestLine -Level PASS -Message 'No cumulative jumps above threshold while parsing this log.'
    }
    else {
        Write-TestLine -Level FAIL -Message ("Found {0} suspicious cumulative jump(s):" -f $jumps.Count)
        foreach ($j in $jumps) {
            Write-Host ('  {0:HH:mm:ss} {1} {2} -> {3:HH:mm:ss} {4} {5}  wall={6}s cum+={7}s ratio={8}x unlocked={9}' -f `
                    $j.FromTs, $j.FromEv, $j.FromText, $j.ToTs, $j.ToEv, $j.ToText, $j.WallSec, $j.DeltaSec, $j.Ratio, $j.Unlocked)
        }
    }

    # Expected unlocked estimate from transitions (simple): sum wall time while LastUnlocked=true between samples.
    $expected = 0.0
    for ($i = 1; $i -lt $samples.Count; $i++) {
        $prev = $samples[$i - 1]
        $cur = $samples[$i]
        $wall = ($cur.TimestampLocal - $prev.TimestampLocal).TotalSeconds
        if ($wall -lt 0) { continue }
        # Credit wall time only when the previous sample said unlocked (interval was unlocked).
        if ($prev.Unlocked -eq $true) {
            $expected += $wall
        }
    }
    $last = $samples[-1]
    Write-Host ''
    Write-Host '--- totals ---'
    Write-Host ("Last log cumulative:     {0} ({1}s)" -f $last.CumulativeText, $last.CumulativeSeconds)
    Write-Host ("Est. unlocked wall time: {0}s (~{1})" -f [int]$expected, (Format-Duration-MonitorStyle -Seconds $expected))
    if ($expected -gt 0) {
        $totRatio = $last.CumulativeSeconds / $expected
        Write-Host ("Log cumulative / est. wall unlocked: {0:F2}x" -f $totRatio)
        if ($totRatio -gt $JumpRatioThreshold) {
            Write-TestLine -Level WARN -Message 'Overall log cumulative exceeds estimated unlocked wall time (overcount likely).'
        }
    }

    if ($StatePath -and (Test-Path -LiteralPath $StatePath)) {
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $stateSec = [double]$state.UnlockedSecondsToday
            $monitorFmt = Format-Duration-MonitorStyle -Seconds $stateSec
            $hoursFmt = Format-Duration-HoursProperty -Seconds $stateSec
            Write-Host ''
            Write-Host '--- state.json ---'
            Write-Host ("UnlockedSecondsToday: {0}" -f $stateSec)
            Write-Host ("Format-Duration (monitor TotalHours): {0}" -f $monitorFmt)
            Write-Host ("Format-Duration (Hours property):     {0}" -f $hoursFmt)
            Write-Host ("Last log cumulative text:             {0}" -f $last.CumulativeText)
            $parsedLog = $last.CumulativeSeconds
            if ([Math]::Abs($stateSec - $parsedLog) -gt ($PollIntervalSeconds * 4 + 30)) {
                Write-TestLine -Level WARN -Message (
                    "state.json ({0:F0}s) disagrees with last log cumulative ({1}s). Possible rewrite, restart, or display mismatch." -f `
                        $stateSec, $parsedLog)
            }
            else {
                Write-TestLine -Level INFO -Message 'state.json is close to last log cumulative (within slack).'
            }
            # Exact half mismatch is a useful fingerprint if Format-Duration ever double-counted hours.
            if ($parsedLog -gt 0 -and [Math]::Abs(($parsedLog / 2.0) - $stateSec) -lt 2) {
                Write-TestLine -Level WARN -Message 'state seconds are ~half of last log cumulative text - investigate Format-Duration / dual writers.'
            }
        }
        catch {
            Write-TestLine -Level WARN -Message ("Could not read state.json: {0}" -f $_.Exception.Message)
        }
    }

    Write-Host ''
    Write-Host 'How to interpret:' -ForegroundColor DarkGray
    Write-Host '  - Jump 00:mm -> 01:mm right after ~30 min unlocked => classic [int]TotalHours rounding (fixed in Format-Duration).' -ForegroundColor DarkGray
    Write-Host '  - Frozen cumulative while unlocked=False => lock path OK (not this bug).' -ForegroundColor DarkGray
    Write-Host '  - Run -SelfTest to confirm Floor vs rounded [int] behavior.' -ForegroundColor DarkGray
    Write-Host '  - Run -Watch after reinstall to confirm live state seconds track ~1.0x wall.' -ForegroundColor DarkGray
    Write-Host ''

    return $(if ($jumps.Count -gt 0) { 2 } else { 0 })
}

function Invoke-WatchMode {
    param(
        [Parameter(Mandatory)][string]$StatePath,
        [int]$WatchSeconds,
        [int]$SampleIntervalSeconds,
        [double]$JumpRatioThreshold,
        [int]$MinGapSeconds,
        [int]$PollIntervalSeconds
    )

    Write-Host ''
    Write-Host '=== Unlocked cumulative live watch ===' -ForegroundColor Cyan
    Write-Host ("State:     {0}" -f $StatePath)
    Write-Host ("Duration:  {0}s  interval={1}s" -f $WatchSeconds, $SampleIntervalSeconds)
    Write-Host 'Stay unlocked/interactive for the whole watch window.' -ForegroundColor Yellow
    Write-Host ''

    if (-not (Test-Path -LiteralPath $StatePath)) {
        Write-TestLine -Level FAIL -Message "state.json not found: $StatePath"
        return 1
    }

    $samples = New-Object System.Collections.ArrayList
    $start = Get-Date
    $deadline = $start.AddSeconds($WatchSeconds)
    $jumpCount = 0

    while ((Get-Date) -lt $deadline) {
        $now = Get-Date
        try {
            $state = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $sec = [double]$state.UnlockedSecondsToday
            $fmt = Format-Duration-MonitorStyle -Seconds $sec
            $null = $samples.Add([pscustomobject]@{
                    TimestampLocal    = $now
                    CumulativeSeconds = $sec
                    CumulativeText    = $fmt
                    LastUnlocked      = [bool]$state.LastUnlocked
                })

            if ($samples.Count -ge 2) {
                $prev = $samples[$samples.Count - 2]
                $cur = $samples[$samples.Count - 1]
                $wall = ($cur.TimestampLocal - $prev.TimestampLocal).TotalSeconds
                $delta = $cur.CumulativeSeconds - $prev.CumulativeSeconds
                $rate = if ($wall -gt 0) { $delta / $wall } else { 0 }
                $mark = ''
                if ($wall -ge $MinGapSeconds -and $delta -gt 0 -and ($delta / $wall) -gt $JumpRatioThreshold) {
                    $mark = ' JUMP'
                    $jumpCount++
                    Write-TestLine -Level FAIL -Message (
                        "t+{0:N0}s  {1} ({2:F1}s)  dCum={3:F1}s wall={4:F1}s rate={5:F2}x{6}" -f `
                            ($now - $start).TotalSeconds, $fmt, $sec, $delta, $wall, $rate, $mark)
                }
                else {
                    Write-TestLine -Level INFO -Message (
                        "t+{0:N0}s  {1} ({2:F1}s)  dCum={3:F1}s wall={4:F1}s rate={5:F2}x lastUnlocked={6}" -f `
                            ($now - $start).TotalSeconds, $fmt, $sec, $delta, $wall, $rate, $cur.LastUnlocked)
                }
            }
            else {
                Write-TestLine -Level INFO -Message ("t+0s  {0} ({1:F1}s) lastUnlocked={2}" -f $fmt, $sec, [bool]$state.LastUnlocked)
            }
        }
        catch {
            Write-TestLine -Level WARN -Message ("Sample failed: {0}" -f $_.Exception.Message)
        }

        Start-Sleep -Seconds $SampleIntervalSeconds
    }

    if ($samples.Count -ge 2) {
        $first = $samples[0]
        $last = $samples[$samples.Count - 1]
        $wall = ($last.TimestampLocal - $first.TimestampLocal).TotalSeconds
        $delta = $last.CumulativeSeconds - $first.CumulativeSeconds
        $ratio = if ($wall -gt 0) { $delta / $wall } else { 0 }
        Write-Host ''
        Write-Host '--- watch summary ---'
        Write-Host ("Wall:     {0:F1}s" -f $wall)
        Write-Host ("Credited: {0:F1}s ({1})" -f $delta, (Format-Duration-MonitorStyle -Seconds $delta))
        Write-Host ("Rate:     {0:F3}x wall (poll={1}s; ideal ~1.0 while unlocked)" -f $ratio, $PollIntervalSeconds)
        Write-Host ("Jumps:    {0}" -f $jumpCount)
        if ($ratio -gt $JumpRatioThreshold) {
            Write-TestLine -Level FAIL -Message 'Watch overall rate exceeds threshold - cumulative overcount reproduced.'
            return 2
        }
        if ($jumpCount -gt 0) {
            Write-TestLine -Level FAIL -Message 'One or more intra-watch jumps exceeded threshold.'
            return 2
        }
        Write-TestLine -Level PASS -Message 'Watch completed without cumulative overcount above threshold.'
        return 0
    }

    Write-TestLine -Level FAIL -Message 'Not enough samples collected.'
    return 1
}

# --- main ---
try {
    if ($SelfTest) {
        Write-Host ''
        Write-Host '=== Unlocked cumulative self-test ===' -ForegroundColor Cyan
        $a = Test-FormatDurationSelfTest
        $b = Test-CreditLoopSelfTest -PollIntervalSeconds 5 -WallSeconds 900
        if ($a -and $b) {
            Write-TestLine -Level PASS -Message 'SelfTest passed.'
            exit 0
        }
        Write-TestLine -Level FAIL -Message 'SelfTest failed.'
        exit 1
    }

    $logDir = Get-ResolvedLogDirectory -Override $LogDirectory -TemplateConfigPath $TemplateConfigPath
    $poll = Get-RuntimePollIntervalSeconds -LogDirectory $logDir -TemplateConfigPath $TemplateConfigPath
    $statePath = Join-Path $logDir 'state.json'

    if ($Watch) {
        $code = Invoke-WatchMode `
            -StatePath $statePath `
            -WatchSeconds $WatchSeconds `
            -SampleIntervalSeconds $SampleIntervalSeconds `
            -JumpRatioThreshold $JumpRatioThreshold `
            -MinGapSeconds ([Math]::Min($MinGapSeconds, $SampleIntervalSeconds)) `
            -PollIntervalSeconds $poll
        exit $code
    }

    if ([string]::IsNullOrWhiteSpace($LogPath)) {
        $LogPath = Join-Path $logDir ('unlocked-time-{0:yyyy-MM-dd}.log' -f $Date)
    }

    $code = Invoke-AnalyzeMode `
        -Path $LogPath `
        -StatePath $statePath `
        -PollIntervalSeconds $poll `
        -JumpRatioThreshold $JumpRatioThreshold `
        -MinGapSeconds $MinGapSeconds
    exit $code
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Test-UnlockedCumulative.ps1 failed' -Source 'Test-UnlockedCumulative'
    throw
}
