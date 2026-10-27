#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Interactive runner for UNLOCKED-TIME-INVESTIGATION-TEST-PLAN.txt.
.DESCRIPTION
  Walks through Steps 1-5 of an unlocked-time investigation for a measured
  account: Test-Session snapshots, background WTS probe targeting that user,
  repeated post-lock samples, Status, and copies of LoginTimeLogs / config /
  errors.log into one output folder for offline analysis.
  Paths and account names are prompted or taken from parameters / runtime config
  (no hardcoded machine users or profile paths).
.PARAMETER TargetUsername
  Measured account (DOMAIN\user, UPN, or SAM). Prompted if omitted.
.PARAMETER OutputRoot
  Parent folder for the run directory (default: current user's Desktop via
  [Environment]::GetFolderPath, else %USERPROFILE%\Desktop).
.PARAMETER ProbeIntervalSeconds
  WTS probe sample interval (default 3).
.PARAMETER ProbeTimeoutSeconds
  Max probe lifetime (default 900).
.PARAMETER StillLockedSampleCount
  How many post-lock Test-Session samples to take (default 6).
.PARAMETER StillLockedIntervalSeconds
  Seconds between post-lock samples (default 30).
.PARAMETER PostLockWaitMinutes
  Extra wait before final Status/collection (default 5).
.EXAMPLE
  .\scripts\Invoke-UnlockedTimeInvestigation.ps1
.EXAMPLE
  .\scripts\Invoke-UnlockedTimeInvestigation.ps1 -TargetUsername 'CONTOSO\UserName'
#>
[CmdletBinding()]
param(
    [string]$TargetUsername = '',

    [string]$OutputRoot = '',

    [ValidateRange(1, 60)]
    [int]$ProbeIntervalSeconds = 3,

    [ValidateRange(60, 7200)]
    [int]$ProbeTimeoutSeconds = 900,

    [ValidateRange(1, 40)]
    [int]$StillLockedSampleCount = 6,

    [ValidateRange(5, 300)]
    [int]$StillLockedIntervalSeconds = 30,

    [ValidateRange(0, 60)]
    [int]$PostLockWaitMinutes = 5
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
    $TargetUsername = (Read-Host 'Measured TargetUsername (DOMAIN\user, UPN, or SAM)').Trim()
}
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
$outDir = Join-Path $OutputRoot ("unlocked-time-test-{0}" -f $runId)
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

function ConvertTo-ProcessArgumentListString {
    # Start-Process joins ArgumentList arrays without reliable quoting; paths with
    # spaces (e.g. OneDrive Desktop) must be a single properly quoted command line.
    param([Parameter(Mandatory)][string[]]$Arguments)
    $parts = foreach ($a in $Arguments) {
        if ($null -eq $a) { continue }
        $s = [string]$a
        if ($s -notmatch '[\s"]') {
            $s
        }
        else {
            '"' + ($s -replace '"', '\"') + '"'
        }
    }
    return (($parts | Where-Object { $null -ne $_ }) -join ' ')
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
        $captureArgLine = ConvertTo-ProcessArgumentListString -Arguments @($argList.ToArray())
        $p = Start-Process -FilePath $psExe -ArgumentList $captureArgLine `
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
    $probeOutFile = Join-Path $outDir 'probe.out.log'
    $argLine = ConvertTo-ProcessArgumentListString -Arguments @(
        '-NoProfile'
        '-ExecutionPolicy'
        'Bypass'
        '-File'
        $probeScript
        '-TargetUsername'
        $TargetUsername
        '-ProbeFile'
        $probeLogFile
        '-SessionQueryCsPath'
        $csPath
        '-IntervalSeconds'
        "$ProbeIntervalSeconds"
        '-TimeoutSeconds'
        "$ProbeTimeoutSeconds"
    )
    $script:ProbeProcess = Start-Process -FilePath $psExe -ArgumentList $argLine `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $probeOutFile `
        -RedirectStandardError $probeErrFile
    Set-Content -LiteralPath $probePidFile -Value $script:ProbeProcess.Id -Encoding ASCII
    Write-Journal -Message ("Started WTS probe PID={0} target={1} log={2}" -f `
            $script:ProbeProcess.Id, $TargetUsername, $probeLogFile)

    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        if (Test-Path -LiteralPath $probeLogFile) {
            try {
                if ((Get-Item -LiteralPath $probeLogFile).Length -gt 0) { break }
            }
            catch { }
        }
        if ($script:ProbeProcess.HasExited) { break }
        Start-Sleep -Milliseconds 200
    }

    if ($script:ProbeProcess.HasExited) {
        $script:ProbeProcess.Refresh()
        $err = ''
        $out = ''
        if (Test-Path -LiteralPath $probeErrFile) {
            $err = Get-Content -LiteralPath $probeErrFile -Raw -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $probeOutFile) {
            $out = Get-Content -LiteralPath $probeOutFile -Raw -ErrorAction SilentlyContinue
        }
        throw ("WTS probe exited early (code={0}). stderr={1} stdout={2}" -f `
                $script:ProbeProcess.ExitCode, $err, $out)
    }
    if (-not (Test-Path -LiteralPath $probeLogFile) -or ((Get-Item -LiteralPath $probeLogFile).Length -le 0)) {
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
        'Unlocked-time investigation run'
        ('RunId: {0}' -f $runId)
        ('OutputDir: {0}' -f $outDir)
        ('RepoRoot: {0}' -f $repoRoot)
        ('Operator: {0}\{1}' -f $env:USERDOMAIN, $env:USERNAME)
        ('Computer: {0}' -f $env:COMPUTERNAME)
        ('TargetUsername: {0}' -f $TargetUsername)
        ('AdministratorProfile: {0}' -f $paths.AdministratorProfile)
        ('LogDirectory: {0}' -f $paths.LogDirectory)
        ('RuntimeConfig: {0}' -f $paths.RuntimeConfigPath)
        ('ProbeIntervalSeconds: {0}' -f $ProbeIntervalSeconds)
        ('ProbeTimeoutSeconds: {0}' -f $ProbeTimeoutSeconds)
        ('StillLockedSampleCount: {0}' -f $StillLockedSampleCount)
        ('StillLockedIntervalSeconds: {0}' -f $StillLockedIntervalSeconds)
        ('PostLockWaitMinutes: {0}' -f $PostLockWaitMinutes)
        ('StartedLocal: {0:yyyy-MM-dd HH:mm:ss}' -f (Get-Date))
        ('StartedUtc: {0:o}' -f [datetime]::UtcNow)
    )
    Set-Content -LiteralPath $metaPath -Value ($meta -join [Environment]::NewLine) -Encoding UTF8
    Set-Content -LiteralPath $journalPath -Value '' -Encoding UTF8

    Write-Banner 'Unlocked-time investigation (interactive)'
    Write-Host ("Output folder : {0}" -f $outDir) -ForegroundColor Green
    Write-Host ("Target user   : {0}" -f $TargetUsername)
    Write-Host ("Operator      : {0}\{1}" -f $env:USERDOMAIN, $env:USERNAME)
    Write-Host ("LogDirectory  : {0}" -f $paths.LogDirectory)
    Write-Host ''
    Write-Host 'Keep this window open as the elevated operator account.'
    Write-Host 'Use a second interactive login for the measured TargetUsername when asked.'
    Write-Journal -Message 'Run started.'

    Write-Host ''
    Write-Host ("End-of-use action '{0}' will use after 1-2 minutes of unlocked use:" -f $TargetUsername) -ForegroundColor Yellow
    Write-Host '  A) Win+L (lock)'
    Write-Host '  B) Switch user / disconnect'
    Write-Host '  C) Walk away with screen still unlocked'
    $endAction = ''
    while ($endAction -notin @('A', 'B', 'C')) {
        $endAction = (Read-Host 'Enter A, B, or C').Trim().ToUpperInvariant()
    }
    Write-Journal -Message ("Planned end action: {0}" -f $endAction)
    Add-Content -LiteralPath $metaPath -Value ("PlannedEndAction: {0}" -f $endAction) -Encoding UTF8

    # --- Step 1 ---
    Write-Banner 'Step 1 — Before target unlocks'
    Wait-Operator -Prompt ("Confirm '{0}' is NOT unlocked-active yet (locked/disconnected/no session). Then continue." -f $TargetUsername)
    $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
        -OutFile (Join-Path $outDir '01-before.txt') `
        -ArgumentList @('-TargetUsername', $TargetUsername)

    # --- Step 2 ---
    Write-Banner 'Step 2 — Start continuous WTS probe for target'
    Start-TargetProbe
    Write-Host ("Probe log: {0}" -f $probeLogFile) -ForegroundColor Green

    # --- Step 3 ---
    Write-Banner 'Step 3 — Target unlocks and uses desktop 1-2 minutes only'
    Wait-Operator -Prompt ("Have '{0}' unlock/sign in and start using the desktop now. Right after unlock is stable, continue HERE (do not wait the full 1-2 minutes yet)." -f $TargetUsername)
    $unlockMark = Get-Date
    Write-Journal -Message ("Unlock mark (operator): {0:yyyy-MM-dd HH:mm:ss}" -f $unlockMark)
    Add-Content -LiteralPath $metaPath -Value ("UnlockMarkLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $unlockMark) -Encoding UTF8
    $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
        -OutFile (Join-Path $outDir '02-target-unlocked.txt') `
        -ArgumentList @('-TargetUsername', $TargetUsername)

    Write-Host ''
    Write-Host ("Let '{0}' use the desktop for about 1-2 minutes of REAL work, then end use with action {1}." -f $TargetUsername, $endAction) -ForegroundColor Yellow
    Wait-Operator -Prompt ("When '{0}' has finished the 1-2 minutes and is ABOUT to perform end action {1} (or just did it within the last few seconds), continue HERE immediately." -f $TargetUsername, $endAction)

    # --- Step 4 ---
    Write-Banner 'Step 4 — Right after end-of-use + repeated samples'
    $endMark = Get-Date
    Write-Journal -Message ("End-of-use mark (operator): {0:yyyy-MM-dd HH:mm:ss} action={1}" -f $endMark, $endAction)
    Add-Content -LiteralPath $metaPath -Value ("EndOfUseMarkLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $endMark) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("EndOfUseAction: {0}" -f $endAction) -Encoding UTF8

    $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
        -OutFile (Join-Path $outDir '03-right-after-end.txt') `
        -ArgumentList @('-TargetUsername', $TargetUsername)

    for ($i = 1; $i -le $StillLockedSampleCount; $i++) {
        Write-Host ("Post-end sample {0}/{1} in {2}s..." -f $i, $StillLockedSampleCount, $StillLockedIntervalSeconds)
        Start-Sleep -Seconds $StillLockedIntervalSeconds
        $name = '04-post-end-{0:00}.txt' -f $i
        $null = Invoke-CapturedScript -ScriptPath $testSessionScript `
            -OutFile (Join-Path $outDir $name) `
            -ArgumentList @('-TargetUsername', $TargetUsername)
    }

    # --- Step 5 ---
    Write-Banner ("Step 5 — Wait {0} more minute(s), then Status + collect logs" -f $PostLockWaitMinutes)
    if ($PostLockWaitMinutes -gt 0) {
        Write-Host ("Waiting {0} minute(s). Keep target locked/away if that was the plan." -f $PostLockWaitMinutes)
        Write-Journal -Message ("Post-end wait start ({0} min)" -f $PostLockWaitMinutes)
        Start-Sleep -Seconds ($PostLockWaitMinutes * 60)
        Write-Journal -Message 'Post-end wait finished'
    }

    $null = Invoke-CapturedScript -ScriptPath $statusScript `
        -OutFile (Join-Path $outDir '05-status.txt')

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

    $probeSummary = Join-Path $outDir '06-probe-summary.txt'
    if (Test-Path -LiteralPath $probeLogFile) {
        $probeLines = @(Get-Content -LiteralPath $probeLogFile -ErrorAction SilentlyContinue)
        $falseCount = @($probeLines | Where-Object { $_ -match '\bunlocked=False\b' }).Count
        $trueCount = @($probeLines | Where-Object { $_ -match '\bunlocked=True\b' }).Count
        $summary = @(
            ("ProbeLog: {0}" -f $probeLogFile)
            ("Lines: {0}" -f $probeLines.Count)
            ("unlocked=True samples: {0}" -f $trueCount)
            ("unlocked=False samples: {0}" -f $falseCount)
            ''
            '--- last 40 lines ---'
        ) + @($probeLines | Select-Object -Last 40)
        Set-Content -LiteralPath $probeSummary -Value ($summary -join [Environment]::NewLine) -Encoding UTF8
    }

    $finished = Get-Date
    Add-Content -LiteralPath $metaPath -Value ("FinishedLocal: {0:yyyy-MM-dd HH:mm:ss}" -f $finished) -Encoding UTF8
    Add-Content -LiteralPath $metaPath -Value ("FinishedUtc: {0:o}" -f $finished.ToUniversalTime()) -Encoding UTF8
    Write-Journal -Message 'Run finished successfully.'

    $readme = @(
        'Unlocked-time investigation — output folder'
        '==========================================='
        ''
        ("OutputDir: {0}" -f $outDir)
        ("TargetUsername: {0}" -f $TargetUsername)
        ''
        'Key files:'
        '  00-run-meta.txt          - run parameters and wall-clock marks'
        '  00-journal.txt           - step timeline'
        '  01-before.txt            - Test-Session before unlock'
        '  02-target-unlocked.txt   - Test-Session right after unlock'
        '  03-right-after-end.txt   - Test-Session right after end-of-use'
        '  04-post-end-NN.txt       - repeated Test-Session samples'
        '  05-status.txt            - Status.ps1 after wait'
        '  06-probe-summary.txt     - WTS probe True/False counts + tail'
        '  wts-target-probe.log     - full continuous WTS probe for TargetUsername'
        '  LoginTimeLogs\           - copy of monitor day logs / state / service.log'
        '  config.json / errors.log - runtime config and error log (if present)'
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
