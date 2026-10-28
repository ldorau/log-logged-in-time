#Requires -Version 5.1
<#
.SYNOPSIS
  One-account SessionQuery lock probe: samples IsUserUnlocked while you Win+L.
.DESCRIPTION
  Starts scripts\WtsLockProbe.ps1 in a background process that keeps polling
  SessionQuery (same API as LoginTimeLogger: SignalFile / SecurityLog / WTS /
  Desktop) into %TEMP%. You lock and unlock on this account, then press Enter.
  Reports whether any sample saw unlocked=False. Prefer source=SignalFile after
  Install. Does not require a second account. Does not read/write LoginTimeLogs.
.PARAMETER TargetUsername
  Account to query (default: USERDOMAIN\USERNAME, else USERNAME).
.PARAMETER IntervalSeconds
  Probe sample interval (default 3).
.PARAMETER ProbeTimeoutSeconds
  Max time the background probe may run (default 300).
.EXAMPLE
  .\scripts\Test-WtsLockProbe.ps1
.EXAMPLE
  .\scripts\Test-WtsLockProbe.ps1 -TargetUsername 'GER\ldorau'
#>
[CmdletBinding()]
param(
    [string]$TargetUsername = '',

    [ValidateRange(1, 60)]
    [int]$IntervalSeconds = 3,

    [ValidateRange(30, 3600)]
    [int]$ProbeTimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
$probeScript = Join-Path $scriptDir 'WtsLockProbe.ps1'

if (-not (Test-Path -LiteralPath $csPath)) {
    throw "SessionQuery.cs not found at '$csPath'."
}
if (-not (Test-Path -LiteralPath $probeScript)) {
    throw "WtsLockProbe.ps1 not found at '$probeScript'."
}

if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
    if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN) -and
        -not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $TargetUsername = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    }
    else {
        $TargetUsername = $env:USERNAME
    }
}
$User = $TargetUsername.Trim()
if ([string]::IsNullOrWhiteSpace($User)) {
    throw 'TargetUsername is empty. Pass -TargetUsername or run while logged on interactively.'
}

$userFolder = ($User -replace '[\\/:*?"<>|]', '_').Trim()
if ([string]::IsNullOrWhiteSpace($userFolder)) {
    $userFolder = 'current'
}

function Write-TestLine {
    param([string]$Message, [ValidateSet('INFO', 'PASS', 'FAIL', 'WARN')][string]$Level = 'INFO')
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    switch ($Level) {
        'PASS' { Write-Host $line -ForegroundColor Green }
        'FAIL' { Write-Host $line -ForegroundColor Red }
        'WARN' { Write-Host $line -ForegroundColor Yellow }
        default { Write-Host $line }
    }
}

$probeDir = Join-Path $env:TEMP ("WtsLockProbe-{0}" -f $userFolder)
$probeFile = Join-Path $probeDir 'wts-lock-probe.log'
$probePidFile = Join-Path $probeDir 'probe.pid'
$probeErrFile = Join-Path $probeDir 'probe.err.log'

try {
    if (-not ('SessionQuery' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -LiteralPath $csPath -Raw -Encoding UTF8) -Language CSharp -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $probeDir -Force | Out-Null
    Remove-Item -LiteralPath $probeFile, $probeErrFile -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $probePidFile) {
        $oldPid = Get-Content -LiteralPath $probePidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $probePidFile -Force -ErrorAction SilentlyContinue
    }

    Write-Host ''
    Write-Host '=== SessionQuery lock probe (one-account) ===' -ForegroundColor Cyan
    Write-Host ("TargetUsername : {0}" -f $User)
    Write-Host ("Probe log      : {0}" -f $probeFile)
    Write-Host ("Probe script   : {0}" -f $probeScript)
    Write-Host ("Interval       : {0}s" -f $IntervalSeconds)
    Write-Host 'Uses SessionQuery (SignalFile / SecurityLog / WTS / Desktop - same as LoginTimeLogger).'
    Write-Host 'After Install, expect source=SignalFile while Win+L is held.'
    Write-Host 'No Administrator LoginTimeLogs are read or written.'
    Write-Host ''

    Write-TestLine -Level INFO -Message ("Phase 1: verifying '{0}' is currently UNLOCKED..." -f $User)
    if (-not [SessionQuery]::IsUserUnlocked($User)) {
        Write-TestLine -Level FAIL -Message @"
Phase 1 failed: account '$User' is not unlocked-active right now.
LastError=$([SessionQuery]::LastError)
Unlock the desktop, then re-run:
  .\scripts\Test-WtsLockProbe.ps1
"@
        exit 1
    }
    Write-TestLine -Level PASS -Message (
        "Phase 1 passed: unlocked (source={0}; flags={1})." -f `
            ([SessionQuery]::LastLockSource), ([SessionQuery]::LastWtsSessionFlags))

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Quote paths with spaces (Start-Process ArgumentList arrays are unreliable).
    $quoteArg = {
        param([string]$s)
        if ($s -notmatch '[\s"]') { return $s }
        return ('"{0}"' -f ($s -replace '"', '\"'))
    }
    $probeArgLine = @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        (& $quoteArg $probeScript)
        '-TargetUsername'
        (& $quoteArg $User)
        '-ProbeFile'
        (& $quoteArg $probeFile)
        '-SessionQueryCsPath'
        (& $quoteArg $csPath)
        '-IntervalSeconds'
        "$IntervalSeconds"
        '-TimeoutSeconds'
        "$ProbeTimeoutSeconds"
    ) -join ' '
    $probeOutFile = Join-Path $probeDir 'probe.out.log'
    $probe = Start-Process -FilePath $psExe -ArgumentList $probeArgLine `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $probeOutFile `
        -RedirectStandardError $probeErrFile
    Set-Content -LiteralPath $probePidFile -Value $probe.Id -Encoding ASCII

    $readyDeadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $readyDeadline) {
        if (Test-Path -LiteralPath $probeFile) {
            try {
                if ((Get-Item -LiteralPath $probeFile).Length -gt 0) { break }
            }
            catch { }
        }
        if ($probe.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }

    if ($probe.HasExited) {
        $probe.Refresh()
        $errText = ''
        $outText = ''
        if (Test-Path -LiteralPath $probeErrFile) {
            $errText = Get-Content -LiteralPath $probeErrFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $probeOutFile) {
            $outText = Get-Content -LiteralPath $probeOutFile -Raw -ErrorAction SilentlyContinue
        }
        Write-TestLine -Level FAIL -Message @"
Probe process exited early (code=$($probe.ExitCode)).
Stderr:
$errText
Stdout:
$outText
"@
        exit 2
    }

    if (-not (Test-Path -LiteralPath $probeFile) -or ((Get-Item -LiteralPath $probeFile).Length -le 0)) {
        Write-TestLine -Level FAIL -Message "Probe is running but log was not created: $probeFile"
        exit 2
    }

    Write-TestLine -Level INFO -Message 'Probe is running and writing samples.'
    Write-Host ''
    Write-Host 'Phase 2: LOCK for at least 15-30 seconds, then UNLOCK' -ForegroundColor Cyan
    Write-Host '  1) Press Win+L (lock)'
    Write-Host '  2) Wait 15-30+ seconds while locked'
    Write-Host ("  3) Unlock as {0}" -f $User)
    Write-Host '  4) Return to this window and press Enter'
    Write-Host ''
    Write-Host 'This console may freeze while locked; that is normal.'
    Write-Host ''

    $null = Read-Host 'After you have locked (long enough) AND unlocked, press Enter here'

    if (-not $probe.HasExited) {
        Stop-Process -Id $probe.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400
    }
    Remove-Item -LiteralPath $probePidFile -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $probeFile)) {
        Write-TestLine -Level FAIL -Message "Probe log was not created: $probeFile"
        exit 2
    }

    Write-Host ''
    Write-Host '--- probe log ---' -ForegroundColor DarkCyan
    Get-Content -LiteralPath $probeFile | ForEach-Object { Write-Host $_ }
    Write-Host '-----------------' -ForegroundColor DarkCyan
    Write-Host ''

    $lines = @(Get-Content -LiteralPath $probeFile -ErrorAction Stop)
    $sampleLines = @($lines | Where-Object { $_ -match '\bunlocked=' })
    $sawLocked = @($sampleLines | Where-Object { $_ -match '\bunlocked=False\b' }).Count -gt 0
    $sawUnlocked = @($sampleLines | Where-Object { $_ -match '\bunlocked=True\b' }).Count -gt 0

    if ($sampleLines.Count -eq 0) {
        Write-TestLine -Level FAIL -Message "No WTS samples in probe log: $probeFile"
        exit 2
    }

    Write-TestLine -Level INFO -Message ("Samples: {0}; unlocked=True seen={1}; unlocked=False seen={2}" -f `
            $sampleLines.Count, $sawUnlocked, $sawLocked)

    $signalFileFalse = @($sampleLines | Where-Object {
            $_ -match '\bunlocked=False\b' -and $_ -match '\bsource=SignalFile\b'
        }).Count

    if (-not $sawLocked) {
        Write-TestLine -Level FAIL -Message @"
Probe did NOT see unlocked=False while you were locked.
If LoginTimeLoggerLockSignal is not Running, Install/start it first (SignalFile path).
Test-LockCycle still validates SessionSwitch events separately.
Probe log: $probeFile
Tip: lock for 30+ seconds and re-run.
"@
        exit 3
    }

    Write-TestLine -Level PASS -Message 'Probe saw unlocked=False during the lock window.'
    if ($signalFileFalse -gt 0) {
        Write-TestLine -Level PASS -Message ("Probe used source=SignalFile on {0} False sample(s)." -f $signalFileFalse)
    }
    else {
        Write-TestLine -Level WARN -Message 'False samples were not SignalFile - check lock-signal watcher / SecurityLog.'
    }
    if ($sawUnlocked) {
        Write-TestLine -Level PASS -Message 'Probe also saw unlocked=True (expected before/after lock).'
    }

    $post = [SessionQuery]::IsUserUnlocked($User)
    Write-TestLine -Level INFO -Message ("Post-check IsUserUnlocked({0})={1}" -f $User, $post)

    Write-TestLine -Level PASS -Message @"
SessionQuery lock probe PASSED for USER='$User'.
Probe log: $probeFile
"@
    exit 0
}
catch {
    Write-Host '---------- ERROR ----------' -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    Write-Host '---------------------------' -ForegroundColor Red
    exit 1
}
finally {
    if (Test-Path -LiteralPath $probePidFile) {
        $pidText = Get-Content -LiteralPath $probePidFile -ErrorAction SilentlyContinue
        if ($pidText) {
            Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $probePidFile -Force -ErrorAction SilentlyContinue
    }
}
