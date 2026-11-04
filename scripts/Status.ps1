#Requires -Version 5.1
<#
.SYNOPSIS
  Shows LoginTimeLogger task state and today's unlocked-time summary.
.DESCRIPTION
  Readable by the install admin (full) or the measured target user (read-only
  logs/config). Does not require elevation. Target users cannot change ACLs
  or start the SYSTEM monitor task.
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'LoginTimeLogger',
    [string]$TemplateConfigPath,
    [string]$ConfigPath
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

function Send-StatusSmtpFail {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$AlertKey
    )
    if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
        $null = Send-LoginTimeSmtpAlert -Subject $Subject -Body $Body -AlertKey $AlertKey
    }
}

function New-StatusVerifyAlertBody {
    <#
      Builds a diagnostic SMTP body for Status helper FAIL/ERROR (exit code,
      script paths, config hints, captured verify output, recent service.log).
    #>
    param(
        [Parameter(Mandatory)][string]$Summary,
        [int]$ExitCode = 0,
        [string]$ScriptPath = '',
        [string]$ProvidersPath = '',
        [string]$CapturedOutput = '',
        [string]$ExceptionText = '',
        [string]$LogDirectory = '',
        [hashtable]$Extra = @{}
    )

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add($Summary)
    $lines.Add('')
    $lines.Add('--- debug ---')
    $lines.Add(('ExitCode: {0}' -f $ExitCode))
    if (-not [string]::IsNullOrWhiteSpace($ScriptPath)) {
        $lines.Add(('Script: {0}' -f $ScriptPath))
        $lines.Add(('ScriptExists: {0}' -f (Test-Path -LiteralPath $ScriptPath)))
    }
    if (-not [string]::IsNullOrWhiteSpace($ProvidersPath)) {
        $lines.Add(('ProvidersPath: {0}' -f $ProvidersPath))
        $lines.Add(('ProvidersExists: {0}' -f (Test-Path -LiteralPath $ProvidersPath)))
    }
    $hint = ''
    if (Get-Command Get-PowerShellFileExitHint -ErrorAction SilentlyContinue) {
        $hint = Get-PowerShellFileExitHint -ExitCode $ExitCode -ScriptPath $ScriptPath
    }
    if (-not [string]::IsNullOrWhiteSpace($hint)) {
        $lines.Add(('Hint:{0}' -f $hint))
    }
    if ($Extra -and $Extra.Count -gt 0) {
        foreach ($key in ($Extra.Keys | Sort-Object)) {
            $lines.Add(('{0}: {1}' -f $key, $Extra[$key]))
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ExceptionText)) {
        $lines.Add('')
        $lines.Add('--- exception ---')
        $lines.Add((Limit-TextForAlert -Text $ExceptionText -MaxChars 4000))
    }
    $lines.Add('')
    $lines.Add('--- verify output ---')
    $outText = Limit-TextForAlert -Text $CapturedOutput -MaxChars 12000
    if ([string]::IsNullOrWhiteSpace($outText)) {
        $lines.Add('(no output captured)')
    }
    else {
        $lines.Add($outText)
    }

    $serviceLog = $null
    if (-not [string]::IsNullOrWhiteSpace($LogDirectory)) {
        $candidate = Join-Path $LogDirectory 'service.log'
        if (Test-Path -LiteralPath $candidate) {
            $serviceLog = $candidate
        }
    }
    if ($serviceLog) {
        try {
            $svcTail = @(Get-Content -LiteralPath $serviceLog -Tail 40 -ErrorAction Stop |
                    Where-Object { $_ -match '\[(WARN|ERROR)\]|DNS-force|DoH|VPN|SCP-Allow|firewall|ServerDNS' })
            if ($svcTail.Count -gt 0) {
                $lines.Add('')
                $lines.Add(('--- service.log matches (tail filter; file={0}) ---' -f $serviceLog))
                $lines.Add((Limit-TextForAlert -Text ($svcTail -join [Environment]::NewLine) -MaxChars 4000))
            }
        }
        catch { }
    }

    return ($lines -join [Environment]::NewLine)
}

try {
    $null = Initialize-ErrorLog -ConfigPath $TemplateConfigPath
    if (Get-Command Initialize-SmtpAlerts -ErrorAction SilentlyContinue) {
        $null = Initialize-SmtpAlerts -ConfigPath $TemplateConfigPath
    }
    $administratorProfile = if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        $env:USERPROFILE
    }
    else {
        Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
    }

    $configPath = $null
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        $configPath = $ConfigPath
    }
    else {
        $fromTask = Get-LoginTimeLoggerRuntimeConfigPath -TaskName $TaskName
        if ($fromTask) {
            $configPath = $fromTask
        }
    }

    if (Test-Path -LiteralPath $TemplateConfigPath) {
        try {
            $template = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $tplAdmin = Get-OptionalPropertyValue -InputObject $template -Name 'AdministratorProfile'
            if (-not [string]::IsNullOrWhiteSpace([string]$tplAdmin)) {
                $administratorProfile = [string]$tplAdmin
            }
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "Failed to parse template config '{0}'" -f $TemplateConfigPath)
        }
    }
    else {
        Write-Host ("WARNING: Template config not found: {0}" -f $TemplateConfigPath) -ForegroundColor Yellow
    }

    if (-not $configPath) {
        $runtimeConfigPath = Join-Path $administratorProfile 'LoginTimeLogger\config.json'
        if (Test-Path -LiteralPath $runtimeConfigPath) {
            $configPath = $runtimeConfigPath
        }
        else {
            Write-Host ("WARNING: Runtime config not found at '{0}'. Falling back to template." -f $runtimeConfigPath) -ForegroundColor Yellow
            $configPath = $TemplateConfigPath
        }
    }

    try {
        $null = Initialize-ErrorLog -ConfigPath $configPath
        if (Get-Command Initialize-SmtpAlerts -ErrorAction SilentlyContinue) {
            $null = Initialize-SmtpAlerts -ConfigPath $configPath
        }
    }
    catch { }
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    $targetUsername = '(not set)'
    $lockSignalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'
    $scpOnLockEnabled = $false
    $scpHost = ''
    $scpPort = 22
    $serverDns = ''

    if (Test-Path -LiteralPath $configPath) {
        try {
            $raw = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $cfgTarget = Get-OptionalPropertyValue -InputObject $raw -Name 'TargetUsername'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgTarget)) {
                $targetUsername = [string]$cfgTarget
            }
            $cfgAdminProfile = Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgAdminProfile)) {
                $administratorProfile = [string]$cfgAdminProfile
            }
            $cfgLogDir = Get-OptionalPropertyValue -InputObject $raw -Name 'LogDirectory'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgLogDir)) {
                $logDirectory = [string]$cfgLogDir
            }
            else {
                $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
            }
            $cfgLockSignal = Get-OptionalPropertyValue -InputObject $raw -Name 'LockSignalPath'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgLockSignal)) {
                $lockSignalPath = [string]$cfgLockSignal
            }
            $cfgServerDns = Get-OptionalPropertyValue -InputObject $raw -Name 'ServerDNS'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgServerDns)) {
                $serverDns = [string]$cfgServerDns.Trim()
            }
            $cfgScpEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpOnLockEnabled'
            if ($null -ne $cfgScpEnabled) {
                $scpOnLockEnabled = [bool]$cfgScpEnabled
            }
            $cfgScpHost = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpHost'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpHost)) {
                $scpHost = [string]$cfgScpHost
            }
            $cfgScpPort = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpPort'
            if ($null -ne $cfgScpPort -and [int]$cfgScpPort -gt 0) {
                $scpPort = [int]$cfgScpPort
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
    # LastTaskResult is Int32; high-bit HRESULTs are negative. Do not use [uint32]0x800710E0
    # (PS parses that hex as Int32 then the cast overflows).
    $schedTaskReady = [uint32]0x41300
    $schedTaskRunning = [uint32]0x41301
    $schedInstanceRunning = ConvertTo-UInt32Code -Value ([int]0x800710E0)

    $taskState = $null
    $lastTaskResult = $null
    $lastRunTime = $null
    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        if ($task) {
            $info = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction Stop
            $taskState = [string]$task.State
            $lastTaskResult = ConvertTo-UInt32Code -Value $info.LastTaskResult
            $lastRunTime = $info.LastRunTime
            $resultHex = '0x{0:X8}' -f $lastTaskResult
            $resultNote = ''
            if ($lastTaskResult -eq [uint32]0) {
                $resultNote = 'success'
            }
            elseif ($lastTaskResult -eq $schedTaskRunning) {
                $resultNote = 'SCHED_S_TASK_RUNNING (normal while monitor is up)'
            }
            elseif ($lastTaskResult -eq $schedTaskReady) {
                $resultNote = 'SCHED_S_TASK_READY'
            }
            elseif ($lastTaskResult -eq $schedInstanceRunning) {
                # Common after Start-ScheduledTask when MultipleInstances=IgnoreNew and monitor already holds the mutex.
                $resultNote = 'HRESULT 0x800710E0 (often instance-already-running; OK if mutex/process healthy)'
            }
            Write-Host ("Task: {0} | State: {1} | LastResult: {2} ({3}){4} | LastRun: {5}" -f `
                    $TaskName, $task.State, $lastTaskResult, $resultHex, $(
                        if ($resultNote) { " = $resultNote" } else { '' }
                    ), $info.LastRunTime)

            $lastResultOk = ($lastTaskResult -eq [uint32]0) -or
                ($lastTaskResult -eq $schedTaskRunning) -or
                ($lastTaskResult -eq $schedTaskReady -and $taskState -eq 'Ready') -or
                ($lastTaskResult -eq $schedInstanceRunning)
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
        $lockInfo = $null
        try { $lockInfo = Get-ScheduledTaskInfo -TaskName 'LoginTimeLoggerLockSignal' -ErrorAction SilentlyContinue } catch { }
        $lockLast = if ($lockInfo) { '0x{0:X8}' -f (ConvertTo-UInt32Code -Value $lockInfo.LastTaskResult) } else { '?' }
        Write-Host ("Lock signal task: LoginTimeLoggerLockSignal | State: {0} | LastResult: {1}" -f `
                $lockSignalTask.State, $lockLast)
        if ($lockSignalTask.State -ne 'Running') {
            Write-Host 'WARNING: Lock signal task is not Running - Win+L may not be detected. Start-ScheduledTask LoginTimeLoggerLockSignal (or log off/on).' -ForegroundColor Yellow
        }
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
            $ageSec = $null
            if (-not [string]::IsNullOrWhiteSpace([string]$sig.UpdatedUtc)) {
                try {
                    $updatedUtc = [datetime]::Parse([string]$sig.UpdatedUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
                    $ageSec = [int]([datetime]::UtcNow - $updatedUtc.ToUniversalTime()).TotalSeconds
                }
                catch { }
            }
            if ($null -ne $ageSec -and $ageSec -gt 90) {
                Write-Host ("WARNING: Lock signal file is stale ({0}s old) - watcher likely dead." -f $ageSec) -ForegroundColor Yellow
            }
            elseif ($null -ne $ageSec) {
                Write-Host ("  age: {0}s (ok if under ~90s)" -f $ageSec)
            }
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

    # --- DoH / DNS-over-HTTPS verify (Block-DoH-Firewall.ps1 -Verify) ---
    $dohCandidates = @(
        (Join-Path $scriptDir 'Block-DoH-Firewall.ps1')
        (Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Block-DoH-Firewall.ps1')
    )
    $dohScript = $dohCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $dohScript) {
        Write-Host 'DNS-over-HTTP: SKIP (Block-DoH-Firewall.ps1 not found)' -ForegroundColor Yellow
    }
    else {
        $dohProviders = Join-Path (Split-Path -Parent $dohScript) 'Block-DoH-Providers.json'
        Write-Host 'Checking DNS-over-HTTP (DoH) block via Block-DoH-Firewall.ps1 -Verify (may take a minute)...' -ForegroundColor DarkGray
        try {
            # Omit -Quiet so FAIL emails include rule/connectivity diagnostics.
            $dohScriptArgs = @('-Verify')
            if (Test-Path -LiteralPath $dohProviders) {
                $dohScriptArgs += @('-ProvidersPath', $dohProviders)
            }

            $dohResult = Invoke-WindowsPowerShellFile -ScriptPath $dohScript -ScriptArgument $dohScriptArgs -CaptureOutput
            $dohExit = [int]$dohResult.ExitCode
            $dohExtra = @{
                ConfigPath = $configPath
                IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
            }

            if ($dohExit -eq 0) {
                Write-Host 'DNS-over-HTTP: OK' -ForegroundColor Green
            }
            elseif ($dohExit -eq 2) {
                Write-Host 'DNS-over-HTTP: INCONCLUSIVE (rules/tests did not confirm a block)' -ForegroundColor Yellow
            }
            elseif ($dohExit -eq -196608) {
                $msg = 'DNS-over-HTTP: ERROR (helper failed to start)'
                Write-Host ($msg + (Get-PowerShellFileExitHint -ExitCode $dohExit -ScriptPath $dohScript)) -ForegroundColor Red
                $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $dohExit -ScriptPath $dohScript `
                    -ProvidersPath $dohProviders -CapturedOutput $dohResult.Output `
                    -LogDirectory $logDirectory -Extra $dohExtra
                Send-StatusSmtpFail -Subject 'Status FAIL: DNS-over-HTTP' -Body $body -AlertKey 'status-doh-error'
            }
            else {
                $msg = 'DNS-over-HTTP: FAIL (reachable endpoints or missing/mismatched firewall rules)'
                Write-Host $msg -ForegroundColor Red
                $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $dohExit -ScriptPath $dohScript `
                    -ProvidersPath $dohProviders -CapturedOutput $dohResult.Output `
                    -LogDirectory $logDirectory -Extra $dohExtra
                Send-StatusSmtpFail -Subject 'Status FAIL: DNS-over-HTTP' -Body $body -AlertKey 'status-doh-fail'
            }
        }
        catch {
            Write-Host ("DNS-over-HTTP: ERROR ({0})" -f $_.Exception.Message) -ForegroundColor Red
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "DoH verify failed; script='{0}'" -f $dohScript)
            $body = New-StatusVerifyAlertBody -Summary 'DNS-over-HTTP: ERROR' -ScriptPath $dohScript `
                -ProvidersPath $dohProviders -ExceptionText ("{0}`r`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) `
                -LogDirectory $logDirectory -Extra @{ ConfigPath = $configPath }
            Send-StatusSmtpFail -Subject 'Status FAIL: DNS-over-HTTP' -Body $body -AlertKey 'status-doh-error'
        }
    }

    # --- VPN block verify (Block-Vpn-Firewall.ps1 -Verify) ---
    $vpnCandidates = @(
        (Join-Path $scriptDir 'Block-Vpn-Firewall.ps1')
        (Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Block-Vpn-Firewall.ps1')
    )
    $vpnScript = $vpnCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $vpnScript) {
        Write-Host 'VPN-Block: SKIP (Block-Vpn-Firewall.ps1 not found)' -ForegroundColor Yellow
    }
    else {
        $vpnProviders = Join-Path (Split-Path -Parent $vpnScript) 'Block-Vpn-Providers.json'
        Write-Host 'Checking VPN block via Block-Vpn-Firewall.ps1 -Verify (may take a minute)...' -ForegroundColor DarkGray
        try {
            $vpnScriptArgs = @('-Verify')
            if (Test-Path -LiteralPath $vpnProviders) {
                $vpnScriptArgs += @('-ProvidersPath', $vpnProviders)
            }

            $vpnResult = Invoke-WindowsPowerShellFile -ScriptPath $vpnScript -ScriptArgument $vpnScriptArgs -CaptureOutput
            $vpnExit = [int]$vpnResult.ExitCode
            $vpnExtra = @{
                ConfigPath = $configPath
                IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                    [Security.Principal.WindowsBuiltInRole]::Administrator)
            }

            if ($vpnExit -eq 0) {
                Write-Host 'VPN-Block: OK' -ForegroundColor Green
            }
            elseif ($vpnExit -eq 2) {
                Write-Host 'VPN-Block: INCONCLUSIVE (rules/tests did not confirm a block)' -ForegroundColor Yellow
            }
            elseif ($vpnExit -eq -196608) {
                $msg = 'VPN-Block: ERROR (helper failed to start)'
                Write-Host ($msg + (Get-PowerShellFileExitHint -ExitCode $vpnExit -ScriptPath $vpnScript)) -ForegroundColor Red
                $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $vpnExit -ScriptPath $vpnScript `
                    -ProvidersPath $vpnProviders -CapturedOutput $vpnResult.Output `
                    -LogDirectory $logDirectory -Extra $vpnExtra
                Send-StatusSmtpFail -Subject 'Status FAIL: VPN-Block' -Body $body -AlertKey 'status-vpn-error'
            }
            else {
                $msg = 'VPN-Block: FAIL (reachable endpoints or missing/mismatched firewall rules)'
                Write-Host $msg -ForegroundColor Red
                $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $vpnExit -ScriptPath $vpnScript `
                    -ProvidersPath $vpnProviders -CapturedOutput $vpnResult.Output `
                    -LogDirectory $logDirectory -Extra $vpnExtra
                Send-StatusSmtpFail -Subject 'Status FAIL: VPN-Block' -Body $body -AlertKey 'status-vpn-fail'
            }
        }
        catch {
            Write-Host ("VPN-Block: ERROR ({0})" -f $_.Exception.Message) -ForegroundColor Red
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                "VPN verify failed; script='{0}'" -f $vpnScript)
            $body = New-StatusVerifyAlertBody -Summary 'VPN-Block: ERROR' -ScriptPath $vpnScript `
                -ProvidersPath $vpnProviders -ExceptionText ("{0}`r`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) `
                -LogDirectory $logDirectory -Extra @{ ConfigPath = $configPath }
            Send-StatusSmtpFail -Subject 'Status FAIL: VPN-Block' -Body $body -AlertKey 'status-vpn-error'
        }
    }

    # --- Local DNS force verify (Force-DnsToLocalResolver.ps1 -Verify) ---
    if ([string]::IsNullOrWhiteSpace($serverDns)) {
        $skipMsg = 'DNS-Force: SKIP (ServerDNS empty in config)'
        Write-Host $skipMsg -ForegroundColor DarkGray
        Send-StatusSmtpFail -Subject 'DNS-force skipped' -Body $skipMsg -AlertKey 'status-dns-force-skip'
    }
    else {
        $dnsForceCandidates = @(
            (Join-Path $scriptDir 'Force-DnsToLocalResolver.ps1')
            (Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Force-DnsToLocalResolver.ps1')
        )
        $dnsForceScript = $dnsForceCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $dnsForceScript) {
            $skipMsg = 'DNS-Force: SKIP (Force-DnsToLocalResolver.ps1 not found)'
            Write-Host $skipMsg -ForegroundColor Yellow
            Send-StatusSmtpFail -Subject 'DNS-force skipped' -Body $skipMsg -AlertKey 'status-dns-force-skip-script'
        }
        else {
            Write-Host ("Checking DNS-Force (local resolver {0}) via Force-DnsToLocalResolver.ps1 -Verify..." -f $serverDns) -ForegroundColor DarkGray
            try {
                $dnsForceScriptArgs = @('-DnsServer', $serverDns, '-Verify')
                $dnsForceResult = Invoke-WindowsPowerShellFile -ScriptPath $dnsForceScript `
                    -ScriptArgument $dnsForceScriptArgs -CaptureOutput
                $dnsForceExit = [int]$dnsForceResult.ExitCode
                $dnsForceExtra = @{
                    ConfigPath = $configPath
                    ServerDNS  = $serverDns
                    IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                        [Security.Principal.WindowsBuiltInRole]::Administrator)
                }

                if ($dnsForceExit -eq 0) {
                    Write-Host 'DNS-Force: OK' -ForegroundColor Green
                }
                elseif ($dnsForceExit -eq -196608) {
                    $msg = 'DNS-Force: ERROR (helper failed to start)'
                    Write-Host ($msg + (Get-PowerShellFileExitHint -ExitCode $dnsForceExit -ScriptPath $dnsForceScript)) -ForegroundColor Red
                    $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $dnsForceExit -ScriptPath $dnsForceScript `
                        -CapturedOutput $dnsForceResult.Output -LogDirectory $logDirectory -Extra $dnsForceExtra
                    Send-StatusSmtpFail -Subject 'Status FAIL: DNS-Force' -Body $body -AlertKey 'status-dns-force-error'
                }
                else {
                    $msg = 'DNS-Force: FAIL (adapter DNS or firewall rules not forcing the LAN resolver)'
                    Write-Host $msg -ForegroundColor Red
                    $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $dnsForceExit -ScriptPath $dnsForceScript `
                        -CapturedOutput $dnsForceResult.Output -LogDirectory $logDirectory -Extra $dnsForceExtra
                    Send-StatusSmtpFail -Subject 'Status FAIL: DNS-Force' -Body $body -AlertKey 'status-dns-force-fail'
                }
            }
            catch {
                Write-Host ("DNS-Force: ERROR ({0})" -f $_.Exception.Message) -ForegroundColor Red
                $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                    "DNS-Force verify failed; script='{0}'" -f $dnsForceScript)
                $body = New-StatusVerifyAlertBody -Summary 'DNS-Force: ERROR' -ScriptPath $dnsForceScript `
                    -ExceptionText ("{0}`r`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) `
                    -LogDirectory $logDirectory -Extra @{ ConfigPath = $configPath; ServerDNS = $serverDns }
                Send-StatusSmtpFail -Subject 'Status FAIL: DNS-Force' -Body $body -AlertKey 'status-dns-force-error'
            }
        }
    }

    # --- SCP outbound allow verify (Allow-ScpOutboundFirewall.ps1 -Verify) ---
    if (-not $scpOnLockEnabled -or [string]::IsNullOrWhiteSpace($scpHost)) {
        Write-Host 'SCP-Allow: SKIP (ScpOnLock disabled or ScpHost empty)' -ForegroundColor DarkGray
    }
    else {
        $scpAllowCandidates = @(
            (Join-Path $scriptDir 'Allow-ScpOutboundFirewall.ps1')
            (Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Allow-ScpOutboundFirewall.ps1')
        )
        $scpAllowScript = $scpAllowCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
        if (-not $scpAllowScript) {
            Write-Host 'SCP-Allow: SKIP (Allow-ScpOutboundFirewall.ps1 not found)' -ForegroundColor Yellow
        }
        else {
            Write-Host ("Checking SCP-Allow firewall rule for {0}:{1}..." -f $scpHost, $scpPort) -ForegroundColor DarkGray
            try {
                $scpAllowScriptArgs = @(
                    '-RemoteHost', $scpHost,
                    '-RemotePort', "$scpPort",
                    '-Verify'
                )
                $scpAllowResult = Invoke-WindowsPowerShellFile -ScriptPath $scpAllowScript `
                    -ScriptArgument $scpAllowScriptArgs -CaptureOutput
                $scpAllowExit = [int]$scpAllowResult.ExitCode
                $scpAllowExtra = @{
                    ConfigPath = $configPath
                    ScpHost    = $scpHost
                    ScpPort    = $scpPort
                    IsElevated = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
                        [Security.Principal.WindowsBuiltInRole]::Administrator)
                }

                if ($scpAllowExit -eq 0) {
                    Write-Host 'SCP-Allow: OK' -ForegroundColor Green
                }
                elseif ($scpAllowExit -eq -196608) {
                    $msg = 'SCP-Allow: ERROR (helper failed to start)'
                    Write-Host ($msg + (Get-PowerShellFileExitHint -ExitCode $scpAllowExit -ScriptPath $scpAllowScript)) -ForegroundColor Red
                    $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $scpAllowExit -ScriptPath $scpAllowScript `
                        -CapturedOutput $scpAllowResult.Output -LogDirectory $logDirectory -Extra $scpAllowExtra
                    Send-StatusSmtpFail -Subject 'Status FAIL: SCP-Allow' -Body $body -AlertKey 'status-scp-allow-error'
                }
                else {
                    $msg = 'SCP-Allow: FAIL (outbound Allow rule missing or mismatched)'
                    Write-Host $msg -ForegroundColor Red
                    $body = New-StatusVerifyAlertBody -Summary $msg -ExitCode $scpAllowExit -ScriptPath $scpAllowScript `
                        -CapturedOutput $scpAllowResult.Output -LogDirectory $logDirectory -Extra $scpAllowExtra
                    Send-StatusSmtpFail -Subject 'Status FAIL: SCP-Allow' -Body $body -AlertKey 'status-scp-allow-fail'
                }
            }
            catch {
                Write-Host ("SCP-Allow: ERROR ({0})" -f $_.Exception.Message) -ForegroundColor Red
                $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Status' -Context (
                    "SCP-Allow verify failed; script='{0}'" -f $scpAllowScript)
                $body = New-StatusVerifyAlertBody -Summary 'SCP-Allow: ERROR' -ScriptPath $scpAllowScript `
                    -ExceptionText ("{0}`r`n{1}" -f $_.Exception.Message, $_.ScriptStackTrace) `
                    -LogDirectory $logDirectory -Extra @{ ConfigPath = $configPath; ScpHost = $scpHost; ScpPort = $scpPort }
                Send-StatusSmtpFail -Subject 'Status FAIL: SCP-Allow' -Body $body -AlertKey 'status-scp-allow-error'
            }
        }
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Status.ps1 failed' -Source 'Status'
    throw
}
