#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Shows LoginTimeLogger task state and today's unlocked-time summary.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'LoginTimeLogger',
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
if (Test-Path -LiteralPath $commonErrorPath) {
    . $commonErrorPath
}
else {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
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
            if (-not [string]::IsNullOrWhiteSpace([string]$template.AdministratorProfile)) {
                $administratorProfile = [string]$template.AdministratorProfile
                $null = Initialize-ErrorLog -AdministratorProfile $administratorProfile
            }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to parse template config '{0}'" -f $TemplateConfigPath)
        }
    }
    else {
        $null = Write-ErrorMessage -Level WARN -Source 'Status' -Message "Template config not found: $TemplateConfigPath"
    }
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    $runtimeConfigPath = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
    $configPath = $runtimeConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        $null = Write-ErrorMessage -Level WARN -Source 'Status' -Message (
            "Runtime config not found at '$runtimeConfigPath'. Falling back to template.")
        $configPath = $TemplateConfigPath
    }

    $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    $targetUsername = '(not set)'
    $lockSignalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'

    if (Test-Path -LiteralPath $configPath) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.TargetUsername)) {
                $targetUsername = [string]$raw.TargetUsername
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
                $administratorProfile = [string]$raw.AdministratorProfile
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
                $logDirectory = [string]$raw.LogDirectory
            }
            else {
                $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
            }
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.LockSignalPath)) {
                $lockSignalPath = [string]$raw.LockSignalPath
            }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to parse config '{0}'" -f $configPath)
        }
    }
    else {
        $null = Write-ErrorMessage -Level WARN -Source 'Status' -Message "No config file available at '$configPath'."
    }

    # Scheduler success / informational codes (not monitor failures).
    # 0x0      = completed successfully (also seen while some hosts keep Running)
    # 0x41300  = SCHED_S_TASK_READY
    # 0x41301  = SCHED_S_TASK_RUNNING (normal while the long-running monitor is up)
    $schedTaskReady = 0x41300
    $schedTaskRunning = 0x41301

    $taskState = $null
    $lastTaskResult = $null
    $lastRunTime = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            $taskState = [string]$task.State
            $lastTaskResult = [int]$info.LastTaskResult
            $lastRunTime = $info.LastRunTime
            $resultHex = '0x{0:X}' -f $lastTaskResult
            $resultNote = ''
            if ($lastTaskResult -eq 0) {
                $resultNote = 'success'
            }
            elseif ($lastTaskResult -eq $schedTaskRunning) {
                $resultNote = 'SCHED_S_TASK_RUNNING (normal while monitor is up)'
            }
            elseif ($lastTaskResult -eq $schedTaskReady) {
                $resultNote = 'SCHED_S_TASK_READY'
            }
            Write-Host ("Task: {0} | State: {1} | LastResult: {2} ({3}){4} | LastRun: {5}" -f `
                    $TaskName, $task.State, $lastTaskResult, $resultHex, $(
                        if ($resultNote) { " = $resultNote" } else { '' }
                    ), $info.LastRunTime)

            $lastResultOk = ($lastTaskResult -eq 0) -or
                ($lastTaskResult -eq $schedTaskRunning) -or
                ($lastTaskResult -eq $schedTaskReady -and $taskState -eq 'Ready')
            if (-not $lastResultOk) {
                Write-Host ("WARNING: Task last result {0} ({1}) looks like a failure. Check '{2}\service.log', '{3}', and Task Scheduler history." -f `
                        $lastTaskResult, $resultHex, $logDirectory, (Get-ErrorLogPath)) -ForegroundColor Yellow
            }
        }
        else {
            Write-Host "Task '$TaskName' is not installed."
        }
    }
    catch {
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
            "Failed to query scheduled task '{0}'" -f $TaskName)
    }

    # Process / mutex liveness (task State alone can be Ready while a monitor still runs, or vice versa).
    $monitorMutexHeld = $false
    $monitorMutexPresent = $false
    $mutexProbeError = $null
    try {
        $existing = $null
        $opened = $false
        try {
            $opened = [System.Threading.Mutex]::TryOpenExisting('Global\LoginTimeLogger.Monitor', [ref]$existing)
        }
        catch [System.UnauthorizedAccessException] {
            throw
        }
        catch {
            # Fallback when TryOpenExisting is unavailable or fails differently.
            $existing = [System.Threading.Mutex]::OpenExisting('Global\LoginTimeLogger.Monitor')
            $opened = $true
        }
        if ($opened -and $existing) {
            $monitorMutexPresent = $true
            try {
                if ($existing.WaitOne(0, $false)) {
                    $existing.ReleaseMutex()
                    $monitorMutexHeld = $false
                }
                else {
                    $monitorMutexHeld = $true
                }
            }
            finally {
                $existing.Dispose()
            }
        }
    }
    catch [System.Threading.WaitHandleCannotBeOpenedException] {
        $monitorMutexPresent = $false
        $monitorMutexHeld = $false
    }
    catch [System.UnauthorizedAccessException] {
        $monitorMutexPresent = $false
        $monitorMutexHeld = $false
        $mutexProbeError = 'access denied (reinstall so mutex ACL allows Administrators)'
    }
    catch [System.Management.Automation.MethodInvocationException] {
        # TryOpenExisting wraps UnauthorizedAccessException on some hosts.
        if ($_.Exception.InnerException -is [System.UnauthorizedAccessException]) {
            $monitorMutexPresent = $false
            $monitorMutexHeld = $false
            $mutexProbeError = 'access denied (reinstall so mutex ACL allows Administrators)'
        }
        else {
            $mutexProbeError = $_.Exception.Message
        }
    }
    catch [System.Threading.AbandonedMutexException] {
        $monitorMutexPresent = $true
        $monitorMutexHeld = $false
    }
    catch {
        $mutexProbeError = $_.Exception.Message
        Write-Verbose -Message ("Mutex probe failed: {0}" -f $_.Exception.Message)
    }

    $monitorProcesses = @()
    try {
        $monitorProcesses = @(
            Get-CimInstance -ClassName Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
                Where-Object { $_.CommandLine -and ($_.CommandLine -match 'LoginTimeLogger\.ps1') } |
                Select-Object ProcessId, CommandLine
        )
    }
    catch {
        Write-Verbose -Message ("Process probe failed: {0}" -f $_.Exception.Message)
    }

    $processRunning = $monitorProcesses.Count -gt 0
    # Process evidence is authoritative; mutex held or Running+0x41301 are supporting signals.
    $monitorHealthy = $processRunning -or $monitorMutexHeld

    Write-Host ("Monitor mutex:   present={0}; held={1}{2}" -f $monitorMutexPresent, $monitorMutexHeld, $(
            if ($mutexProbeError) { "; probe={0}" -f $mutexProbeError } else { '' }
        ))
    Write-Host ("Monitor process: running={0}; count={1}" -f $processRunning, $monitorProcesses.Count)
    if ($processRunning) {
        foreach ($proc in $monitorProcesses) {
            Write-Host ("  PID {0}" -f $proc.ProcessId)
        }
    }
    if ($processRunning -and -not $monitorMutexPresent) {
        Write-Host 'Note: monitor process is up but Global mutex was not visible (reinstall refreshes mutex ACL for Status).' -ForegroundColor Yellow
    }
    if ($taskState -and ($taskState -ne 'Running') -and ($monitorMutexHeld -or $processRunning)) {
        Write-Host 'Note: task State is not Running, but a monitor instance appears active (mutex/process).' -ForegroundColor Yellow
    }
    elseif ($taskState -eq 'Running' -and -not $monitorMutexHeld -and -not $processRunning) {
        Write-Host 'Note: task State is Running, but no monitor mutex/process was detected yet.' -ForegroundColor Yellow
    }
    if ($monitorHealthy) {
        Write-Host 'Overall: monitor looks healthy.' -ForegroundColor Green
    }

    Write-Host "Config file:     $configPath"
    Write-Host "Target username: $targetUsername"
    Write-Host "Log directory:   $logDirectory"

    $lockSignalTask = Get-ScheduledTask -TaskName 'LoginTimeLoggerLockSignal' -ErrorAction SilentlyContinue
    if ($lockSignalTask) {
        Write-Host ("Lock signal task: LoginTimeLoggerLockSignal | State: {0}" -f $lockSignalTask.State)
    }
    else {
        Write-Host 'Lock signal task: LoginTimeLoggerLockSignal is not installed.' -ForegroundColor Yellow
    }

    if (Test-Path -LiteralPath $lockSignalPath) {
        try {
            $sig = Get-Content -LiteralPath $lockSignalPath -Raw -Encoding UTF8 | ConvertFrom-Json
            Write-Host ("Lock signal file: Locked={0}; Reason={1}; UpdatedLocal={2}; Source={3}" -f `
                    $sig.Locked, $sig.Reason, $sig.UpdatedLocal, $sig.Source)
            Write-Host ("  path: {0}" -f $lockSignalPath)
        }
        catch {
            Write-Host ("Lock signal file present but unreadable: {0}" -f $lockSignalPath) -ForegroundColor Yellow
        }
    }
    else {
        Write-Host ("Lock signal file missing: {0} (log on as target or Start-ScheduledTask LoginTimeLoggerLockSignal)" -f `
                $lockSignalPath) -ForegroundColor Yellow
    }

    $statePath = Join-Path $logDirectory 'state.json'
    $summaryPath = Join-Path $logDirectory 'unlocked-time-summary.csv'
    $todayLog = Join-Path $logDirectory ('unlocked-time-{0:yyyy-MM-dd}.log' -f (Get-Date))
    $serviceLog = Join-Path $logDirectory 'service.log'

    if (Test-Path -LiteralPath $statePath) {
        try {
            $state = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $hours = [Math]::Round(([double]$state.UnlockedSecondsToday) / 3600.0, 2)
            Write-Host ("Today ({0}): {1:F0}s (~{2}h) | currently_unlocked_tracking={3}" -f `
                    $state.Date, $state.UnlockedSecondsToday, $hours, $state.LastUnlocked)
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to read state file '{0}'" -f $statePath)
        }
    }
    else {
        Write-Host "State file not found: $statePath"
    }

    if (Test-Path -LiteralPath $todayLog) {
        try {
            Write-Host '--- today log (last 15 lines) ---'
            Get-Content -LiteralPath $todayLog -Tail 15 -ErrorAction Stop
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to read today log '{0}'" -f $todayLog)
        }
    }
    else {
        Write-Host "Today log not found: $todayLog"
    }

    if (Test-Path -LiteralPath $summaryPath) {
        try {
            Write-Host '--- summary (last 10 days) ---'
            Get-Content -LiteralPath $summaryPath -Tail 10 -ErrorAction Stop
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to read summary '{0}'" -f $summaryPath)
        }
    }

    if (Test-Path -LiteralPath $serviceLog) {
        try {
            Write-Host '--- service.log errors/warnings (last 20 matching lines) ---'
            Select-String -LiteralPath $serviceLog -Pattern '\[(ERROR|WARN)\]' -ErrorAction Stop |
                Select-Object -Last 20 |
                ForEach-Object { $_.Line }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to scan service log '{0}'" -f $serviceLog)
        }
    }

    $errorLogPath = Get-ErrorLogPath
    if (Test-Path -LiteralPath $errorLogPath) {
        try {
            if ($monitorHealthy) {
                Write-Host '--- errors.log (last 20 lines; may include older failures; monitor currently healthy) ---'
            }
            else {
                Write-Host '--- errors.log (last 20 lines) ---'
            }
            Get-Content -LiteralPath $errorLogPath -Tail 20 -ErrorAction Stop
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to read error log '{0}'" -f $errorLogPath)
        }
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Status.ps1 failed' -Source 'Status'
    throw
}
