#Requires -Version 5.1
<#
.SYNOPSIS
  Interactive calibration test: unlocked -> locked (Win+L) -> unlocked.
.DESCRIPTION
  Defaults to the current Windows user ($env:USERNAME). Starts
  scripts\LockCycleWatcher.ps1 in a separate STA process; events are written
  under %TEMP%\LockCycle-<user> (not Administrator).
  After you lock and unlock, press Enter; this script checks the event file.
#>
[CmdletBinding()]
param(
    # Defaults to the account running this script. Override only if needed.
    [string]$TargetUsername = $env:USERNAME,

    [int]$WatcherTimeoutSeconds = 180
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
    throw 'TargetUsername is empty. Pass -TargetUsername or run while logged on interactively.'
}

$User = $TargetUsername.Trim()
# Safe folder segment for TEMP path (SAM names are usually fine; strip path-hostile chars).
$userFolder = ($User -replace '[\\/:*?"<>|]', '_').Trim()
if ([string]::IsNullOrWhiteSpace($userFolder)) {
    $userFolder = 'current'
}

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
$watcherScript = Join-Path $scriptDir 'LockCycleWatcher.ps1'

if (-not (Test-Path -LiteralPath $csPath)) {
    throw "SessionQuery.cs not found at '$csPath'."
}
if (-not (Test-Path -LiteralPath $watcherScript)) {
    throw "LockCycleWatcher.ps1 not found at '$watcherScript'."
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

$eventDir = Join-Path $env:TEMP ("LockCycle-{0}" -f $userFolder)
$eventFile = Join-Path $eventDir 'session-switch.log'
$watcherPidFile = Join-Path $eventDir 'watcher.pid'
$watcherErrFile = Join-Path $eventDir 'watcher.err.log'

try {
    if (-not ('SessionQuery' -as [type])) {
        Add-Type -TypeDefinition (Get-Content -LiteralPath $csPath -Raw -Encoding UTF8) -Language CSharp -ErrorAction Stop
    }

    New-Item -ItemType Directory -Path $eventDir -Force | Out-Null
    Remove-Item -LiteralPath $eventFile, $watcherErrFile -Force -ErrorAction SilentlyContinue

    if (Test-Path -LiteralPath $watcherPidFile) {
        $oldPid = Get-Content -LiteralPath $watcherPidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            Stop-Process -Id ([int]$oldPid) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $watcherPidFile -Force -ErrorAction SilentlyContinue
    }

    $displayUser = $User
    if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN) -and $User -notmatch '[\\@]') {
        $displayUser = '{0}\{1}' -f $env:USERDOMAIN, $User
    }

    Write-Host ''
    Write-Host '=== Lock-cycle calibration test ===' -ForegroundColor Cyan
    Write-Host ("Current USER   : {0}" -f $displayUser)
    Write-Host ("TargetUsername : {0}" -f $User)
    Write-Host 'No Administrator files are read or written.'
    Write-Host ("Event log file : {0}" -f $eventFile)
    Write-Host ("Watcher script : {0}" -f $watcherScript)
    Write-Host 'Lock detection : separate STA watcher + SystemEvents.SessionSwitch'
    Write-Host 'Note: LoginTimeLogger prefers SignalFile/SecurityLog; this test only validates SessionSwitch events.'
    Write-Host ''

    Write-TestLine -Level INFO -Message ("Phase 1: verifying '{0}' is currently UNLOCKED and active..." -f $User)
    if (-not [SessionQuery]::IsUserUnlocked($User)) {
        Write-TestLine -Level FAIL -Message @"
Phase 1 failed: account '$User' is not unlocked-active right now.
LastError=$([SessionQuery]::LastError)
Sign in interactively as that user, unlock the desktop, then re-run:
  .\scripts\Test-LockCycle.ps1
"@
        exit 1
    }
    $s = $null
    try { $s = [SessionQuery]::FindUserSession($User) } catch { $s = $null }
    if (-not $s) {
        $userPart = $User
        if ($User -match '\\') { $userPart = ($User -split '\\')[-1] }
        elseif ($User -match '@') { $userPart = ($User -split '@')[0] }
        $s = [SessionQuery]::GetSessions() |
            Where-Object { $_.UserName -eq $userPart } |
            Select-Object -First 1
    }
    if ($s) {
        Write-TestLine -Level PASS -Message (
            "Phase 1 passed: unlocked-active (SessionId={0}; LockSource={1}; WtsFlags={2})." -f `
                $s.SessionId, $s.LockSource, $s.WtsSessionFlags)
    }
    else {
        Write-TestLine -Level PASS -Message (
            "Phase 1 passed: unlocked-active (LockSource={0}; WtsFlags={1})." -f `
                ([SessionQuery]::LastLockSource), ([SessionQuery]::LastWtsSessionFlags))
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $watcherArgs = @(
        '-NoProfile'
        '-STA'
        '-ExecutionPolicy', 'Bypass'
        '-File', $watcherScript
        '-EventFile', $eventFile
        '-TimeoutSeconds', "$WatcherTimeoutSeconds"
    )
    $watcher = Start-Process -FilePath $psExe -ArgumentList $watcherArgs `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardError $watcherErrFile
    Set-Content -LiteralPath $watcherPidFile -Value $watcher.Id -Encoding ASCII

    # Wait until watcher creates the log or fails
    $readyDeadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $readyDeadline) {
        if (Test-Path -LiteralPath $eventFile) { break }
        if ($watcher.HasExited) { break }
        Start-Sleep -Milliseconds 100
    }

    if ($watcher.HasExited) {
        $errText = ''
        if (Test-Path -LiteralPath $watcherErrFile) {
            $errText = Get-Content -LiteralPath $watcherErrFile -Raw -ErrorAction SilentlyContinue
        }
        Write-TestLine -Level FAIL -Message @"
Watcher process exited early (code=$($watcher.ExitCode)).
EventFile exists: $(Test-Path -LiteralPath $eventFile)
Stderr:
$errText
"@
        if (Test-Path -LiteralPath $eventFile) {
            Write-Host '--- event file ---' -ForegroundColor DarkCyan
            Get-Content -LiteralPath $eventFile | ForEach-Object { Write-Host $_ }
        }
        exit 2
    }

    if (-not (Test-Path -LiteralPath $eventFile)) {
        Write-TestLine -Level FAIL -Message "Watcher is running but event file was not created: $eventFile"
        exit 2
    }

    Write-TestLine -Level INFO -Message 'Watcher is running and event file was created.'

    Write-Host ''
    Write-Host 'Phase 2 + 3: LOCK then UNLOCK' -ForegroundColor Cyan
    Write-Host '  1) Press Win+L (lock)'
    Write-Host ("  2) Unlock and sign back in as {0}" -f $displayUser)
    Write-Host '  3) Return to this window and press Enter'
    Write-Host ''
    Write-Host 'The watcher records SessionLock/SessionUnlock under %TEMP%.'
    Write-Host 'This console may freeze while locked; that is normal.'
    Write-Host ''

    $null = Read-Host 'After you have locked AND unlocked, press Enter here'

    if (-not $watcher.HasExited) {
        Stop-Process -Id $watcher.Id -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }
    Remove-Item -LiteralPath $watcherPidFile -Force -ErrorAction SilentlyContinue

    if (-not (Test-Path -LiteralPath $eventFile)) {
        Write-TestLine -Level FAIL -Message "Event file was not created: $eventFile"
        exit 2
    }

    Write-Host ''
    Write-Host '--- watcher event file ---' -ForegroundColor DarkCyan
    Get-Content -LiteralPath $eventFile | ForEach-Object { Write-Host $_ }
    Write-Host '--------------------------' -ForegroundColor DarkCyan
    Write-Host ''

    $lines = Get-Content -LiteralPath $eventFile -ErrorAction Stop
    $sawLock = @($lines | Where-Object { $_ -match '\[EVENT\]\s+SessionLock\b' }).Count -gt 0
    $sawUnlock = @($lines | Where-Object { $_ -match '\[EVENT\]\s+SessionUnlock\b' }).Count -gt 0

    if (-not $sawLock) {
        Write-TestLine -Level FAIL -Message @"
Phase 2 failed: no SessionLock line in event file.
File: $eventFile
"@
        exit 2
    }
    Write-TestLine -Level PASS -Message 'Phase 2 passed: SessionLock recorded by watcher.'

    if (-not $sawUnlock) {
        Write-TestLine -Level FAIL -Message @"
Phase 3 failed: SessionLock was seen, but no SessionUnlock line.
File: $eventFile
"@
        exit 3
    }
    Write-TestLine -Level PASS -Message 'Phase 3 passed: SessionUnlock recorded by watcher.'

    $unlocked = [SessionQuery]::IsUserUnlocked($User)
    Write-TestLine -Level INFO -Message ("Post-check SessionQuery IsUserUnlocked({0})={1}" -f $User, $unlocked)

    Write-TestLine -Level PASS -Message @"
Lock-cycle calibration PASSED for USER='$User'.
Events file: $eventFile
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
    if (Test-Path -LiteralPath $watcherPidFile) {
        $pidText = Get-Content -LiteralPath $watcherPidFile -ErrorAction SilentlyContinue
        if ($pidText) {
            Stop-Process -Id ([int]$pidText) -Force -ErrorAction SilentlyContinue
        }
        Remove-Item -LiteralPath $watcherPidFile -Force -ErrorAction SilentlyContinue
    }
}
