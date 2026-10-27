#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-account unlocked-time investigation (no second login required).
.DESCRIPTION
  For machines with a single interactive user. Starts a background WTS probe
  (SessionQuery — same path as LoginTimeLogger), then you unlock-use briefly,
  Win+L for a while, unlock, and press Enter. Mid-lock Test-Session samples are
  not possible (console freezes); evidence while locked comes from the probe log
  and LoginTimeLogs after the run.
  Paths/accounts come from parameters, prompts, environment, and runtime config
  (no hardcoded machine users or profile paths).
.PARAMETER TargetUsername
  Measured account. Default: USERDOMAIN\USERNAME when available, else USERNAME.
.PARAMETER OutputRoot
  Parent folder for the run directory (default: Desktop).
.PARAMETER ProbeIntervalSeconds
  WTS probe sample interval (default 3).
.PARAMETER ProbeTimeoutSeconds
  Max probe lifetime (default 900).
.PARAMETER MinLockSeconds
  Suggested minimum lock duration shown in prompts (default 120).
.EXAMPLE
  .\scripts\Invoke-UnlockedTimeInvestigation-OneAccount.ps1
.EXAMPLE
  .\scripts\Invoke-UnlockedTimeInvestigation-OneAccount.ps1 -TargetUsername 'CONTOSO\UserName'
#>
[CmdletBinding()]
param(
    [string]$TargetUsername = '',

    [string]$OutputRoot = '',

    [ValidateRange(1, 60)]
    [int]$ProbeIntervalSeconds = 3,

    [ValidateRange(60, 7200)]
    [int]$ProbeTimeoutSeconds = 900,

    [ValidateRange(15, 3600)]
    [int]$MinLockSeconds = 120
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
$probeScript = Join-Path $scriptDir 'WtsLockProbe.ps1'
$testSessionScript = Join-Path $scriptDir 'Test-Session.ps1'
$statusScript = Join-Path $scriptDir 'Status.ps1'

foreach ($required in @($csPath, $probeScript, $testSessionScript, $statusScript)) {
    if (-not (Test-Path -LiteralPath $required)) {
        throw "Required file missing: $required"
    }
}

if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
    if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN) -and
        -not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $TargetUsername = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERNAME)) {
        $TargetUsername = $env:USERNAME
    }
    else {
        $TargetUsername = (Read-Host 'Measured TargetUsername (DOMAIN\user, UPN, or SAM)').Trim()
    }
}
$TargetUsername = $TargetUsername.Trim()
if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
    throw 'TargetUsername is required.'
}

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ([string]::IsNullOrWhiteSpace($desktop)) {
        $desktop = Join-Path $env:USERPROFILE 'Desktop'
    }
    $OutputRoot = $desktop
}

$runId = Get-Date -Format 'yyyyMMdd-HHmmss'
$outDir = Join-Path $OutputRoot ("unlocked-time-test-oneaccount-{0}" -f $runId)
$logsDir = Join-Path $outDir 'LoginTimeLogs'
$journalPath = Join-Path $outDir '00-journal.txt'
$metaPath = Join-Path $outDir '00-run-meta.txt'
$probePidFile = Join-Path $outDir 'probe.pid'
$probeErrFile = Join-Path $outDir 'probe.err.log'
$probeLogFile = Join-Path $outDir 'wts-target-probe.log'

$script:ProbeProcess = $null

function Write-Banner {
    param([string]$Text)
    Write-Host ''
    Write-Host ('=' * 72) -ForegroundColor Cyan
    Write-Host $Text -ForegroundColor Cyan
    Write-Host ('=' * 72) -ForegroundColor Cyan
}

function Write-Journal {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $journalPath -Value $line -Encoding UTF8
    Write-Host $line
}

function Wait-Operator {
    param([string]$Prompt)
    Write-Host ''
    Write-Host $Prompt -ForegroundColor Yellow
    $null = Read-Host 'Press Enter to continue'
    Write-Journal -Message ("Operator continued: {0}" -f ($Prompt -replace '\s+', ' ').Trim())
}

function Invoke-CapturedScript {
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][string]$OutFile,
        [string[]]$ArgumentList = @()
    )

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-Object System.Collections.ArrayList
    $null = $argList.Add('-NoProfile')
    $null = $argList.Add('-ExecutionPolicy')
    $null = $argList.Add('Bypass')
    $null = $argList.Add('-File')
    $null = $argList.Add($ScriptPath)
    foreach ($a in $ArgumentList) {
        $null = $argList.Add($a)
    }

    Write-Journal -Message ("Running: {0} {1}" -f $ScriptPath, ($ArgumentList -join ' '))
    $tempOut = Join-Path $env:TEMP ("llt-capture-{0}.txt" -f [guid]::NewGuid().ToString('N'))
    $tempErr = Join-Path $env:TEMP ("llt-capture-{0}.err" -f [guid]::NewGuid().ToString('N'))
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList @($argList.ToArray()) `
            -Wait -PassThru -NoNewWindow `
            -RedirectStandardOutput $tempOut `
            -RedirectStandardError $tempErr
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $tempOut) {
            $stdout = Get-Content -LiteralPath $tempOut -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $tempErr) {
            $stderr = Get-Content -LiteralPath $tempErr -Raw -ErrorAction SilentlyContinue
        }
        $combined = New-Object System.Text.StringBuilder
        $null = $combined.AppendLine(('ExitCode: {0}' -f $p.ExitCode))
        $null = $combined.AppendLine(('CapturedUtc: {0:o}' -f [datetime]::UtcNow))
        $null = $combined.AppendLine('--- stdout ---')
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            $null = $combined.AppendLine($stdout.TrimEnd())
        }
        $null = $combined.AppendLine('--- stderr ---')
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            $null = $combined.AppendLine($stderr.TrimEnd())
        }
        Set-Content -LiteralPath $OutFile -Value $combined.ToString() -Encoding UTF8
        if (-not [string]::IsNullOrWhiteSpace($stdout)) {
            Write-Host $stdout
        }
        if (-not [string]::IsNullOrWhiteSpace($stderr)) {
            Write-Host $stderr -ForegroundColor DarkYellow
        }
        Write-Journal -Message ("Saved capture: {0} (exit {1})" -f $OutFile, $p.ExitCode)
        return [int]$p.ExitCode
    }
    finally {
        Remove-Item -LiteralPath $tempOut, $tempErr -Force -ErrorAction SilentlyContinue
    }
}

function Get-AdminPathsFromConfig {
    $administratorProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        $env:USERPROFILE
    }
    else {
        Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
    }

    $runtimeConfig = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
    $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    $errorLog = Join-Path $administratorProfile 'LoginTimeLogger\errors.log'
    $configPath = $runtimeConfig

    if (Test-Path -LiteralPath $runtimeConfig) {
        try {
            $raw = Get-Content -LiteralPath $runtimeConfig -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
                $administratorProfile = [string]$raw.AdministratorProfile
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
                $logDirectory = [string]$raw.LogDirectory
            }
            else {
                $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
            }
            $errorLog = Join-Path $administratorProfile 'LoginTimeLogger\errors.log'
            $configPath = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
        }
        catch { }
    }

    return [pscustomobject]@{
        AdministratorProfile = $administratorProfile
        LogDirectory         = $logDirectory
        ErrorLogPath         = $errorLog
        RuntimeConfigPath    = $configPath
    }
}

function Start-TargetProbe {
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $args = @(
        '-NoProfile'
        '-ExecutionPolicy', 'Bypass'
        '-File', $probeScript
        '-TargetUsername', $TargetUsername
        '-ProbeFile', $probeLogFile
        '-SessionQueryCsPath', $csPath
        '-IntervalSeconds', "$ProbeIntervalSeconds"
        '-TimeoutSeconds', "$ProbeTimeoutSeconds"
    )
    $script:ProbeProcess = Start-Process -FilePath $psExe -ArgumentList $args `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardError $probeErrFile
    Set-Content -LiteralPath $probePidFile -Value $script:ProbeProcess.Id -Encoding ASCII
    Write-Journal -Message ("Started WTS probe PID={0} target={1} log={2}" -f `
            $script:ProbeProcess.Id, $TargetUsername, $probeLogFile)

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $probeLogFile) { break }
        if ($script:ProbeProcess.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }

    if ($script:ProbeProcess.HasExited) {
        $err = ''
        if (Test-Path -LiteralPath $probeErrFile) {
            $err = Get-Content -LiteralPath $probeErrFile -Raw -ErrorAction SilentlyContinue
        }
        throw ("WTS probe exited early (code={0}). stderr={1}" -f $script:ProbeProcess.ExitCode, $err)
    }
    if (-not (Test-Path -LiteralPath $probeLogFile)) {
        throw "WTS probe did not create log file: $probeLogFile"
    }
}

function Stop-TargetProbe {
    $pidToStop = $null
    if ($script:ProbeProcess -and -not $script:ProbeProcess.HasExited) {
        $pidToStop = $script:ProbeProcess.Id
    }
    elseif (Test-Path -LiteralPath $probePidFile) {
        $pidText = Get-Content -LiteralPath $probePidFile -ErrorAction SilentlyContinue
        if ($pidText) { $pidToStop = [int]$pidText }
    }
    if ($pidToStop) {
        Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
        Write-Journal -Message ("Stopped WTS probe PID={0}" -f $pidToStop)
    }
    Remove-Item -LiteralPath $probePidFile -Force -ErrorAction SilentlyContinue
    $script:ProbeProcess = $null
}

try {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    New-Item -ItemType Directory -Path $logsDir -Force | Out-Null

    $paths = Get-AdminPathsFromConfig

    $meta = @(
        'Unlocked-time investigation run (one-account)'
        ('RunId: {0}' -f $runId)
        ('OutputDir: {0}' -f $outDir)
        ('RepoRoot: {0}' -f $repoRoot)
        ('Mode: OneAccount')
        ('Operator: {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        ('Computer: {0}' -f $env:COMPUTERNAME)
        ('TargetUsername: {0}' -f $TargetUsername)
        ('AdministratorProfile: {0}' -f $paths.AdministratorProfile)
        ('LogDirectory: {0}' -f $paths.LogDirectory)
        ('RuntimeConfig: {0}' -f $paths.RuntimeConfigPath)
        ('ProbeIntervalSeconds: {0}' -f $ProbeIntervalSeconds)
        ('ProbeTimeoutSeconds: {0}' -f $ProbeTimeoutSeconds)
        ('MinLockSeconds: {0}' -f $MinLockSeconds)
        ('StartedLocal: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
        ('StartedUtc: {0:o}' -f [datetime]::UtcNow)
    )
    Set-Content -LiteralPath $metaPath -Value ($meta -join [Environment]::NewLine) -Encoding UTF8
    Set-Content -LiteralPath $journalPath -Value '' -Encoding UTF8

    Write-Banner 'Unlocked-time investigation (one-account)'
    Write-Host ("Output folder : {0}" -f $outDir) -ForegroundColor Green
    Write-Host ("Target user   : {0}" -f $TargetUsername)
    Write-Host ("Operator      : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Host ("LogDirectory  : {0}" -f $paths.LogDirectory)
    Write-Host ''
    Write-Host 'This mode does NOT need a second account.'
    Write-Host 'While locked, this console may freeze — that is normal.'
    Write-Host 'Evidence while locked comes from the background WTS probe + LoginTimeLogs.'
    Write-Journal -Message 'Run started (one-account mode).'

    Write-Host ''
    Write-Host 'End-of-use action after ~1-2 minutes of unlocked use:' -ForegroundColor Yellow
    Write-Host '  A) Win+L (lock)  — recommended for this test'
    Write-Host '  B) Switch user / disconnect'
    Write-Host '  C) Walk away with screen still unlocked'
    $endAction = ''
    while ($endAction -notin @('A', 'B', 'C')) {
        $endAction = (Read-Host 'Enter A, B, or C').Trim().ToUpperInvariant()
    }
    Write-Journal -Message ("Planned end action: {0}" -f $endAction)
    Add-Content -LiteralPath $metaPath -Value ("PlannedEndAction: {0}" -f $endAction) -Encoding UTF8

    # --- Step 1: baseline while unlocked ---
    Write-Banner 'Step 1 — Baseline while unlocked'
    Wait-Operator -Prompt 'Confirm you are unlocked and interactive on this account. Then continue.'
    $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
        -OutFile (Join-Path $outDir '01-unlocked-baseline.txt') `
        -ArgumentList @('-TargetUsername', $TargetUsername)

    # --- Step 2: start probe ---
    Write-Banner 'Step 2 — Start continuous WTS probe'
    Start-TargetProbe
    Write-Host ("Probe log: {0}" -f $probeLogFile) -ForegroundColor Green
    $unlockMark = Get-Date
    Write-Journal -Message ("Unlock/baseline mark: {0:yyyy-MM-dd HH:mm:ss}" -f $unlockMark)
    Add-Content -LiteralPath $metaPath -Value ("UnlockMarkLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $unlockMark) -Encoding UTF8

    # --- Step 3: use briefly, lock, unlock, then Enter ---
    Write-Banner 'Step 3 — Short unlocked use, then end action, then return'
    Write-Host ''
    Write-Host 'Do the following now:' -ForegroundColor Yellow
    Write-Host '  1) Use this desktop unlocked for about 1-2 minutes (real work).'
    if ($endAction -eq 'A') {
        Write-Host ("  2) Press Win+L and stay locked for at least {0} seconds." -f $MinLockSeconds)
        Write-Host '  3) Unlock again.'
    }
    elseif ($endAction -eq 'B') {
        Write-Host '  2) Switch user / disconnect and stay away for a few minutes.'
        Write-Host '  3) Sign back in to this account.'
    }
    else {
        Write-Host '  2) Leave the screen unlocked and walk away for several minutes.'
        Write-Host '  3) Return to this session.'
    }
    Write-Host '  4) Return to THIS window and press Enter (only after step 3).'
    Write-Host ''
    Write-Host 'Do not press Enter while locked — wait until you are unlocked again.' -ForegroundColor DarkYellow

    $null = Read-Host 'After unlocked-use + end action + return (unlocked), press Enter here'
    $returnMark = Get-Date
    Write-Journal -Message ("Returned unlocked mark: {0:yyyy-MM-dd HH:mm:ss}" -f $returnMark)
    Add-Content -LiteralPath $metaPath -Value ("ReturnedUnlockedMarkLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $returnMark) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("EndOfUseAction: {0}" -f $endAction) -Encoding UTF8

    # Optional: ask operator for approximate lock start time
    Write-Host ''
    $approxLock = (Read-Host 'Optional: approximate local time you started the end action (HH:mm:ss or blank)').Trim()
    if (-not [string]::IsNullOrWhiteSpace($approxLock)) {
        Add-Content -LiteralPath $metaPath -Value ("ApproxEndActionTimeLocal: {0}" -f $approxLock) -Encoding UTF8
        Write-Journal -Message ("Approx end-action time (operator): {0}" -f $approxLock)
    }

    # --- Step 4: post-return captures ---
    Write-Banner 'Step 4 — Post-return Test-Session + Status + collect logs'
    $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
        -OutFile (Join-Path $outDir '02-after-return.txt') `
        -ArgumentList @('-TargetUsername', $TargetUsername)

    $null = Invoke-CapturedScript -ScriptPath $statusScript `
        -OutFile (Join-Path $outDir '03-status.txt')

    Write-Journal -Message 'Collecting LoginTimeLogs / config / errors.log'
    if (Test-Path -LiteralPath $paths.LogDirectory) {
        Copy-Item -Path (Join-Path $paths.LogDirectory '*') -Destination $logsDir -Force -ErrorAction SilentlyContinue
    }
    else {
        Write-Journal -Message ("WARN: LogDirectory not found: {0}" -f $paths.LogDirectory)
    }
    if (Test-Path -LiteralPath $paths.RuntimeConfigPath) {
        Copy-Item -LiteralPath $paths.RuntimeConfigPath -Destination (Join-Path $outDir 'config.json') -Force
    }
    if (Test-Path -LiteralPath $paths.ErrorLogPath) {
        Copy-Item -LiteralPath $paths.ErrorLogPath -Destination (Join-Path $outDir 'errors.log') -Force
    }

    Stop-TargetProbe

    $probeSummary = Join-Path $outDir '04-probe-summary.txt'
    $sawLocked = $false
    $sawUnlocked = $false
    if (Test-Path -LiteralPath $probeLogFile) {
        $probeLines = @(Get-Content -LiteralPath $probeLogFile -ErrorAction SilentlyContinue)
        $falseCount = @($probeLines | Where-Object { $_ -match '\bunlocked=False\b' }).Count
        $trueCount = @($probeLines | Where-Object { $_ -match '\bunlocked=True\b' }).Count
        $sawLocked = $falseCount -gt 0
        $sawUnlocked = $trueCount -gt 0
        $summary = @(
            ("ProbeLog: {0}" -f $probeLogFile)
            ("Lines: {0}" -f $probeLines.Count)
            ("unlocked=True samples: {0}" -f $trueCount)
            ("unlocked=False samples: {0}" -f $falseCount)
            ("WtsSawLocked: {0}" -f $sawLocked)
            ''
            '--- last 40 lines ---'
        ) + @($probeLines | Select-Object -Last 40)
        Set-Content -LiteralPath $probeSummary -Value ($summary -join [Environment]::NewLine) -Encoding UTF8

        if ($endAction -eq 'A') {
            if ($sawLocked) {
                Write-Host 'WTS probe: saw unlocked=False during the run (good for Win+L).' -ForegroundColor Green
            }
            else {
                Write-Host 'WTS probe: never saw unlocked=False — lock may not have been detected.' -ForegroundColor Yellow
            }
        }
    }

    $finished = Get-Date
    Add-Content -LiteralPath $metaPath -Value ("FinishedLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $finished) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("FinishedUtc: {0:o}" -f $finished.ToUniversalTime()) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("WtsSawLocked: {0}" -f $sawLocked) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("WtsSawUnlocked: {0}" -f $sawUnlocked) -Encoding UTF8
    Write-Journal -Message 'Run finished successfully.'

    $readme = @(
        'Unlocked-time investigation — one-account output folder'
        '======================================================='
        ''
        ("OutputDir: {0}" -f $outDir)
        ("TargetUsername: {0}" -f $TargetUsername)
        'Mode: OneAccount (mid-lock interactive samples are not possible)'
        ''
        'Key files:'
        '  00-run-meta.txt             - parameters and wall-clock marks'
        '  00-journal.txt              - step timeline'
        '  01-unlocked-baseline.txt    - Test-Session before lock'
        '  02-after-return.txt         - Test-Session after unlock/return'
        '  03-status.txt               - Status.ps1'
        '  04-probe-summary.txt        - WTS probe True/False counts + tail'
        '  wts-target-probe.log        - continuous WTS samples (includes lock window)'
        '  LoginTimeLogs\              - monitor day logs / state / service.log'
        '  config.json / errors.log    - runtime config and error log (if present)'
        ''
        'Share this whole folder (zip) for analysis.'
    )
    Set-Content -LiteralPath (Join-Path $outDir 'README.txt') -Value ($readme -join [Environment]::NewLine) -Encoding UTF8

    Write-Banner 'Done'
    Write-Host ("All artifacts saved under:`n  {0}" -f $outDir) -ForegroundColor Green
    Write-Host 'Zip that folder and share it for verification.'
    Write-Host ''
    try {
        Start-Process explorer.exe -ArgumentList $outDir
    }
    catch { }
}
catch {
    Write-Host '---------- ERROR ----------' -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    Write-Host '---------------------------' -ForegroundColor Red
    try { Write-Journal -Message ("ERROR: {0}" -f $_.Exception.Message) } catch { }
    exit 1
}
finally {
    try { Stop-TargetProbe } catch { }
}
