#Requires -Version 5.1
<#
.SYNOPSIS
  Manually copies LoginTimeLogger logs to the configured remote via scp.
.DESCRIPTION
  Reads the LoginTimeLogger runtime config and uploads:
    - every unlocked-time-*.log under LogDirectory
    - all error logs (errors.log / *error*.log, plus Get-ErrorLogPath)
    - debug.log (break / unlock-warn traces under LogDirectory)
    - state.json
    - every *.csv under LogDirectory (recursive), including
      unlocked-time-summary.csv and LogDirectory\bhist\ history CSVs
      (today's history CSVs are refreshed via convert before collect)
    - raw browser History DBs: log-history-op-<profile> and
      log-history-ch-<profile> for every discovered browser profile
      (Default, Profile-1, …); also any non-.csv log-history-* already under
      LogDirectory

  Uses the same OpenSSH scp options as Scp-OnLock.ps1 (key auth, BatchMode),
  plus -v so the transfer lists each file on screen and in the copy log.
  Does not require a screen lock; use -Force when ScpOnLockEnabled is false.

  All screen output is also appended to a log file (see -LogPath).

.PARAMETER ConfigPath
  Runtime config JSON. Default: from LoginTimeLogger scheduled task.
.PARAMETER Force
  Run the copy even when ScpOnLockEnabled is false (still requires host/user/
  directory/identity in config).
.PARAMETER LogPath
  Output log file. Default:
  <AdministratorProfile>\LoginTimeLogger\scp-copy-logs-yyyyMMdd-HHmmss.log
.EXAMPLE
  .\scripts\Copy-LogsViaScp.ps1
.EXAMPLE
  .\scripts\Copy-LogsViaScp.ps1 -Force
.EXAMPLE
  .\scripts\Copy-LogsViaScp.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json' -Force
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [string]$LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir

$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}
. $commonErrorPath

$scpHelperCandidates = @(
    (Join-Path $repoRoot 'src\Scp-OnLock.ps1')
    (Join-Path $env:ProgramFiles 'LoginTimeLogger\src\Scp-OnLock.ps1')
)
$scpHelper = $scpHelperCandidates | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
if (-not $scpHelper) {
    throw "Scp-OnLock.ps1 not found under repo src/ or Program Files."
}
. $scpHelper

$script:CopyLogPath = $null

function Initialize-ScpCopyLog {
    param(
        [string]$LogPath,
        [string]$AdministratorProfile
    )

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $script:CopyLogPath = $LogPath
    }
    else {
        $base = $AdministratorProfile
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = $env:USERPROFILE
        }
        if ([string]::IsNullOrWhiteSpace($base)) {
            $base = $env:TEMP
        }
        $dir = Join-Path $base 'LoginTimeLogger'
        $script:CopyLogPath = Join-Path $dir ('scp-copy-logs-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    }

    $logDir = Split-Path -Parent $script:CopyLogPath
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $header = @(
        ('=== Copy-LogsViaScp log started {0:yyyy-MM-dd HH:mm:ss} ===' -f (Get-Date))
        ('Computer={0}; User={1}' -f $env:COMPUTERNAME, $env:USERNAME)
        ''
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $script:CopyLogPath -Value $header -Encoding UTF8
    return $script:CopyLogPath
}

function Write-ScpCopyLine {
    param(
        [AllowEmptyString()][string]$Message = '',
        [ConsoleColor]$ForegroundColor
    )

    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $Message
    }

    if (-not [string]::IsNullOrWhiteSpace($script:CopyLogPath)) {
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        try {
            Add-Content -LiteralPath $script:CopyLogPath -Value $line -Encoding UTF8
        }
        catch {
            # Screen output already succeeded; do not fail the copy on log I/O.
        }
    }
}

function Write-Check {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = '',
        [ValidateSet('Auto', 'OK', 'FAIL', 'WARN')]
        [string]$Status = 'Auto'
    )
    if ($Status -eq 'Auto') {
        $Status = if ($Ok) { 'OK' } else { 'FAIL' }
    }
    $color = switch ($Status) {
        'OK' { [ConsoleColor]::Green }
        'WARN' { [ConsoleColor]::Yellow }
        default { [ConsoleColor]::Red }
    }
    if ($Detail) {
        Write-ScpCopyLine ("  [{0}] {1} - {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    }
    else {
        Write-ScpCopyLine ("  [{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    }
}

function Resolve-CopyConfigPath {
    param([string]$ConfigPath)

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "ConfigPath not found: '$ConfigPath'."
        }
        return $ConfigPath
    }

    $fromTask = Get-LoginTimeLoggerRuntimeConfigPath
    if ($fromTask) {
        return $fromTask
    }

    $guess = Join-Path $env:USERPROFILE 'LoginTimeLogger\config.json'
    if (Test-Path -LiteralPath $guess) {
        return $guess
    }

    throw @"
Could not find runtime config. Pass -ConfigPath, for example:
  .\scripts\Copy-LogsViaScp.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
"@
}

function Get-ScpConfigObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $adminProfile = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile')
    if ([string]::IsNullOrWhiteSpace($adminProfile)) {
        $adminProfile = $env:USERPROFILE
    }

    $identity = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'ScpIdentityFile')
    if ([string]::IsNullOrWhiteSpace($identity)) {
        $identity = Join-Path $adminProfile 'LoginTimeLogger\ssh\id_ed25519'
    }
    $knownHosts = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'ScpKnownHostsFile')
    if ([string]::IsNullOrWhiteSpace($knownHosts)) {
        $knownHosts = Join-Path $adminProfile 'LoginTimeLogger\ssh\known_hosts'
    }

    $logDirectory = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'LogDirectory')
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path $adminProfile 'LoginTimeLogs'
    }

    $port = 22
    $cfgPort = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpPort'
    if ($null -ne $cfgPort -and [int]$cfgPort -gt 0) {
        $port = [int]$cfgPort
    }

    $scpEnabled = $false
    $cfgScpEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpOnLockEnabled'
    if ($null -ne $cfgScpEnabled) {
        $scpEnabled = [bool]$cfgScpEnabled
    }

    return [pscustomobject]@{
        ConfigPath           = $Path
        ScpOnLockEnabled     = $scpEnabled
        ScpHost              = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'ScpHost')
        ScpUser              = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'ScpUser')
        ScpRemoteDirectory   = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'ScpRemoteDirectory')
        ScpPort              = $port
        ScpIdentityFile      = $identity
        ScpKnownHostsFile    = $knownHosts
        AdministratorProfile = $adminProfile
        LogDirectory         = $logDirectory
        TargetUsername       = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'TargetUsername')
    }
}

function Test-ScpCopyTcpEndpoint {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 5000
    )

    if ([string]::IsNullOrWhiteSpace($HostName) -or $Port -le 0) {
        return [pscustomobject]@{ Ok = $false; Detail = 'Host/port empty' }
    }

    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try { $client.Close() } catch { }
            return [pscustomobject]@{
                Ok     = $false
                Detail = ("TCP connect timed out after {0}ms" -f $TimeoutMs)
            }
        }
        $client.EndConnect($ar)
        return [pscustomobject]@{ Ok = $true; Detail = 'TcpConnectSucceeded=True' }
    }
    catch {
        return [pscustomobject]@{
            Ok     = $false
            Detail = $_.Exception.Message
        }
    }
    finally {
        if ($null -ne $client) {
            try { $client.Close() } catch { }
            try { $client.Dispose() } catch { }
        }
    }
}

function Invoke-ScpOutboundFirewallReconcile {
    param(
        [string]$RemoteHost = '',
        [int]$RemotePort = 0,
        [string]$ConfigPath = ''
    )

    $candidates = @(
        (Join-Path $scriptDir 'Allow-ScpOutboundFirewall.ps1')
        (Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Allow-ScpOutboundFirewall.ps1')
    )
    $scriptPath = $null
    foreach ($c in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            $scriptPath = $c
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        return [pscustomobject]@{
            Ok     = $false
            Detail = 'Allow-ScpOutboundFirewall.ps1 not found'
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $ConfigPath = [string]$resolvedConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        try { $ConfigPath = [string](Get-LoginTimeLoggerRuntimeConfigPath) } catch { }
    }
    if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
        $guess = Join-Path $env:USERPROFILE 'LoginTimeLogger\config.json'
        if (Test-Path -LiteralPath $guess) { $ConfigPath = $guess }
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Build one ArgumentList string: Start-Process + string[] drops/mis-parses
    # -RemoteHost on Windows PowerShell 5.1.
    $argParts = New-Object System.Collections.Generic.List[string]
    foreach ($a in @(
            '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
            '-File', $scriptPath
        )) {
        if ($a -match '[\s"]') {
            $argParts.Add(('"{0}"' -f ($a -replace '"', '\"')))
        }
        else {
            $argParts.Add($a)
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $argParts.Add('-ConfigPath')
        $argParts.Add(('"{0}"' -f ($ConfigPath -replace '"', '\"')))
    }
    if (-not [string]::IsNullOrWhiteSpace($RemoteHost)) {
        $argParts.Add('-RemoteHost')
        $argParts.Add($RemoteHost)
    }
    if ($RemotePort -gt 0) {
        $argParts.Add('-RemotePort')
        $argParts.Add("$RemotePort")
    }
    $argLine = $argParts -join ' '
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
        $code = if ($null -ne $p) { [int]$p.ExitCode } else { -1 }
        return [pscustomobject]@{
            Ok     = ($code -eq 0)
            Detail = ("{0} exit={1}; args={2}" -f $scriptPath, $code, $argLine)
        }
    }
    catch {
        return [pscustomobject]@{
            Ok     = $false
            Detail = $_.Exception.Message
        }
    }
}

function Get-ScpCopyFileBatches {
    <#
      Split manual uploads into small batches so a single OpenSSH connect
      failure / command-line limit does not abort the entire set. Large raw
      History DBs (no .csv / .log / .json) go one per batch.

      Returns PSCustomObject rows @{ Files = string[] }. Avoid List[object] /
      @($list) — those throw ArgumentException ("Niezgodne typy argumentów")
      under PS 5.1 StrictMode.
    #>
    param([Parameter(Mandatory)][string[]]$Files)

    $batches = New-Object System.Collections.ArrayList
    $current = New-Object System.Collections.Generic.List[string]
    $currentBytes = [int64]0
    $maxFiles = 8
    $maxBytes = 32MB

    foreach ($f in @($Files)) {
        if ([string]::IsNullOrWhiteSpace([string]$f) -or -not (Test-Path -LiteralPath ([string]$f))) {
            continue
        }
        $path = [string]$f
        $leaf = Split-Path -Leaf $path
        $ext = [System.IO.Path]::GetExtension($leaf)
        $size = [int64]0
        try { $size = [int64](Get-Item -LiteralPath $path -Force).Length } catch { }

        $isRawHistory = ($leaf -like 'log-history-*') -and ($ext -ne '.csv')
        if ($isRawHistory) {
            if ($current.Count -gt 0) {
                [void]$batches.Add([pscustomobject]@{
                        Files = [string[]]$current.ToArray()
                    })
                $current.Clear()
                $currentBytes = [int64]0
            }
            [void]$batches.Add([pscustomobject]@{
                    Files = [string[]]@($path)
                })
            continue
        }

        if ($current.Count -ge $maxFiles -or
            ($current.Count -gt 0 -and ($currentBytes + $size) -gt $maxBytes)) {
            if ($current.Count -gt 0) {
                [void]$batches.Add([pscustomobject]@{
                        Files = [string[]]$current.ToArray()
                    })
                $current.Clear()
                $currentBytes = [int64]0
            }
        }
        [void]$current.Add($path)
        $currentBytes += $size
    }
    if ($current.Count -gt 0) {
        [void]$batches.Add([pscustomobject]@{
                Files = [string[]]$current.ToArray()
            })
    }
    if ($batches.Count -eq 0) {
        return @()
    }
    # Caller wraps with @(): a single PSCustomObject batch stays one item.
    return [object[]]$batches.ToArray()
}

function Invoke-ScpCopyFiles {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string[]]$Files
    )

    $scpExe = Find-ScpExecutable
    if (-not $scpExe) {
        throw 'scp.exe not found (install OpenSSH Client).'
    }

    $remoteDir = [string]$Config.ScpRemoteDirectory
    if (-not $remoteDir.EndsWith('/')) {
        $remoteDir = $remoteDir + '/'
    }
    $remoteTarget = '{0}@{1}:{2}' -f $Config.ScpUser, $Config.ScpHost, $remoteDir

    # Monitor hardens the key to SYSTEM-only; interactive Copy needs a
    # current-user-readable TEMP copy or OpenSSH reports Load key Permission denied.
    $identityForScp = [string]$Config.ScpIdentityFile
    $tempIdentity = $null
    if (-not (Test-ScpRunningAsLocalSystem)) {
        $tempIdentity = New-ScpIdentityCopyForCurrentUser -IdentityPath $identityForScp
        if ([string]::IsNullOrWhiteSpace($tempIdentity)) {
            throw ((
                    "Cannot prepare a current-user-readable copy of ScpIdentityFile '{0}'. " +
                    'The key is SYSTEM-hardened for the monitor; re-run elevated as an admin ' +
                    'that can adjust the key ACL, or re-run Install/Test-ScpOnLock -GenerateIdentity.'
                ) -f $identityForScp)
        }
        $identityForScp = $tempIdentity
    }

    # Keep @() around the call result; each item is a PSCustomObject with .Files.
    $batches = @(Get-ScpCopyFileBatches -Files $Files)
    if ($batches.Count -eq 0) {
        throw 'No existing files to copy.'
    }

    $allStdout = New-Object System.Collections.Generic.List[string]
    $allStderr = New-Object System.Collections.Generic.List[string]
    $allArgs = New-Object System.Collections.Generic.List[string]
    $lastExit = 0
    $anyTimedOut = $false
    $maxAttempts = 3

    try {
        $batchIndex = 0
        foreach ($batch in $batches) {
            $batchIndex++
            $batchFiles = @()
            if ($null -ne $batch -and $null -ne $batch.PSObject.Properties['Files']) {
                $batchFiles = @($batch.Files)
            }
            elseif ($batch -is [string]) {
                $batchFiles = [string[]]@($batch)
            }
            elseif ($batch -is [System.Array]) {
                $batchFiles = [string[]]@($batch)
            }
            if ($batchFiles.Count -eq 0) { continue }

            $totalBytes = [int64]0
            foreach ($bf in $batchFiles) {
                try { $totalBytes += [int64](Get-Item -LiteralPath $bf -Force).Length } catch { }
            }
            # Scale with payload (~50 KiB/s floor + 60s slack); clamp 120..900.
            $timeoutSeconds = 60 + [int][Math]::Ceiling($totalBytes / 51200.0)
            if ($timeoutSeconds -lt 120) { $timeoutSeconds = 120 }
            if ($timeoutSeconds -gt 900) { $timeoutSeconds = 900 }

            $attempt = 0
            $batchOk = $false
            $batchStdout = ''
            $batchStderr = ''
            $batchExit = -1
            $batchTimedOut = $false
            $batchArgLine = ''

            while ($attempt -lt $maxAttempts -and -not $batchOk) {
                $attempt++
                $argList = New-Object System.Collections.Generic.List[string]
                Add-ScpCommonSshOptions -ArgumentList $argList `
                    -IdentityFile $identityForScp `
                    -Port ([int]$Config.ScpPort) `
                    -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
                    -ConnectTimeoutSeconds 45 `
                    -VerboseSsh
                foreach ($f in $batchFiles) {
                    $argList.Add($f)
                }
                $argList.Add($remoteTarget)

                $batchArgLine = ConvertTo-StartProcessArgumentString -Argument $argList.ToArray()
                Write-ScpCopyLine (
                    "scp batch {0}/{1} attempt {2}/{3} ({4} file(s), timeout {5}s): {6} {7}" -f `
                        $batchIndex, $batches.Count, $attempt, $maxAttempts,
                    $batchFiles.Count, $timeoutSeconds, $scpExe, $batchArgLine) -ForegroundColor DarkGray

                $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-copy-{0}.out' -f [guid]::NewGuid().ToString('N'))
                $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-copy-{0}.err' -f [guid]::NewGuid().ToString('N'))
                try {
                    $run = Invoke-ScpProcessWithTimeout -ScpExe $scpExe -ArgumentList $batchArgLine `
                        -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $timeoutSeconds
                    $batchStdout = ''
                    $batchStderr = ''
                    if (Test-Path -LiteralPath $outFile) {
                        $batchStdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
                    }
                    if (Test-Path -LiteralPath $errFile) {
                        $batchStderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
                    }
                    $batchTimedOut = [bool]$run.TimedOut
                    if ($batchTimedOut) {
                        $batchStderr = (("timed out after {0}s (process killed)`r`n{1}" -f `
                                    $timeoutSeconds, $batchStderr)).Trim()
                    }
                    $batchExit = -1
                    if ($null -ne $run.ExitCode) {
                        $batchExit = [int]$run.ExitCode
                    }

                    $failed = Test-ScpCopyFailed -ExitCode $batchExit -StdErr $batchStderr -TimedOut $batchTimedOut
                    if (-not $failed) {
                        $batchOk = $true
                        break
                    }

                    $connectFail = $false
                    if (Get-Command Test-ScpConnectFailure -ErrorAction SilentlyContinue) {
                        $connectFail = [bool](Test-ScpConnectFailure -StdErr $batchStderr)
                    }
                    else {
                        $connectFail = ($batchStderr -match '(?i)Connection timed out')
                    }

                    if ($connectFail -and $attempt -lt $maxAttempts) {
                        Write-ScpCopyLine (
                            "scp batch {0}: connect failed (attempt {1}); retrying in 5s..." -f `
                                $batchIndex, $attempt) -ForegroundColor Yellow
                        Start-Sleep -Seconds 5
                        continue
                    }
                    break
                }
                finally {
                    Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
                }
            }

            if (-not [string]::IsNullOrWhiteSpace($batchStdout)) { $allStdout.Add($batchStdout) }
            if (-not [string]::IsNullOrWhiteSpace($batchStderr)) { $allStderr.Add($batchStderr) }
            if (-not [string]::IsNullOrWhiteSpace($batchArgLine)) {
                $allArgs.Add(("batch{0}: {1} {2}" -f $batchIndex, $scpExe, $batchArgLine))
            }
            if ($batchTimedOut) { $anyTimedOut = $true }
            $lastExit = $batchExit

            if (-not $batchOk) {
                return [pscustomobject]@{
                    ScpExe       = $scpExe
                    RemoteTarget = $remoteTarget
                    ExitCode     = $lastExit
                    TimedOut     = $anyTimedOut
                    StdOut       = ($allStdout -join "`r`n")
                    StdErr       = @(
                        ("scp batch {0}/{1} failed after {2} attempt(s)." -f `
                                $batchIndex, $batches.Count, $attempt)
                        ("files: {0}" -f ($batchFiles -join '; '))
                        ''
                        ($allStderr -join "`r`n")
                    ) -join "`r`n"
                    ArgPreview   = ($allArgs -join "`r`n")
                }
            }

            Write-ScpCopyLine (
                "scp batch {0}/{1} OK ({2} file(s))" -f `
                    $batchIndex, $batches.Count, $batchFiles.Count) -ForegroundColor DarkGray
        }

        return [pscustomobject]@{
            ScpExe       = $scpExe
            RemoteTarget = $remoteTarget
            ExitCode     = 0
            TimedOut     = $false
            StdOut       = ($allStdout -join "`r`n")
            StdErr       = ($allStderr -join "`r`n")
            ArgPreview   = ($allArgs -join "`r`n")
        }
    }
    finally {
        if (-not [string]::IsNullOrWhiteSpace($tempIdentity) -and
            (Test-Path -LiteralPath $tempIdentity)) {
            Remove-Item -LiteralPath $tempIdentity -Force -ErrorAction SilentlyContinue
        }
    }
}

# --- main ---
$copyResult = $null
$files = @()
$bHistoryStaged = $null

try {
    $null = Initialize-ErrorLog -ConfigPath (Join-Path $repoRoot 'config\config.json')

    $resolvedConfigPath = Resolve-CopyConfigPath -ConfigPath $ConfigPath
    $cfg = Get-ScpConfigObject -Path $resolvedConfigPath
    if (-not [string]::IsNullOrWhiteSpace($cfg.AdministratorProfile)) {
        $null = Initialize-ErrorLog -AdministratorProfile $cfg.AdministratorProfile
    }

    $null = Initialize-ScpCopyLog -LogPath $LogPath -AdministratorProfile $cfg.AdministratorProfile

    Write-ScpCopyLine '=== Copy-LogsViaScp ===' -ForegroundColor Cyan
    Write-ScpCopyLine ("Config: {0}" -f $cfg.ConfigPath)
    Write-ScpCopyLine ("LogDirectory: {0}" -f $cfg.LogDirectory)
    Write-ScpCopyLine ("Error log file: {0}" -f (Get-ErrorLogPath))
    Write-ScpCopyLine ("Copy log file:  {0}" -f $script:CopyLogPath)
    Write-ScpCopyLine ''

    Write-ScpCopyLine 'Step 1: configuration checks' -ForegroundColor Cyan
    Write-Check -Name 'ScpOnLockEnabled' -Ok ($cfg.ScpOnLockEnabled -or $Force) -Detail $(
        if ($cfg.ScpOnLockEnabled) { 'true' }
        elseif ($Force) { 'false (continuing because -Force)' }
        else { 'false (enable in config or pass -Force)' }
    )
    Write-Check -Name 'ScpHost' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpHost)) -Detail $(if ($cfg.ScpHost) { $cfg.ScpHost } else { 'empty' })
    Write-Check -Name 'ScpUser' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpUser)) -Detail $(if ($cfg.ScpUser) { $cfg.ScpUser } else { 'empty' })
    Write-Check -Name 'ScpRemoteDirectory' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpRemoteDirectory)) -Detail $(if ($cfg.ScpRemoteDirectory) { $cfg.ScpRemoteDirectory } else { 'empty' })
    Write-Check -Name 'ScpPort' -Ok ($cfg.ScpPort -gt 0) -Detail "$($cfg.ScpPort)"
    Write-Check -Name 'LogDirectory' -Ok (
        -not [string]::IsNullOrWhiteSpace($cfg.LogDirectory) -and (Test-Path -LiteralPath $cfg.LogDirectory)
    ) -Detail $(if ($cfg.LogDirectory) { $cfg.LogDirectory } else { 'empty' })

    $identityExists = Test-Path -LiteralPath $cfg.ScpIdentityFile
    Write-Check -Name 'ScpIdentityFile exists' -Ok $identityExists -Detail $(
        if ($identityExists) { $cfg.ScpIdentityFile }
        else { "missing: $($cfg.ScpIdentityFile) (re-run Install or .\scripts\Test-ScpOnLock.ps1 -GenerateIdentity)" }
    )

    $scpExe = Find-ScpExecutable
    Write-Check -Name 'scp.exe' -Ok (-not [string]::IsNullOrWhiteSpace($scpExe)) -Detail $(if ($scpExe) { $scpExe } else { 'not found' })

    $configReady = ($cfg.ScpOnLockEnabled -or $Force) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpHost) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpUser) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpRemoteDirectory) `
        -and $identityExists `
        -and $scpExe

    if (-not $configReady) {
        Write-ScpCopyLine ''
        Write-ScpCopyLine 'RESULT: configuration incomplete; scp not attempted.' -ForegroundColor Red
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
        exit 1
    }

    $runtimeCfg = [pscustomobject]@{
        ScpOnLockEnabled   = $true
        ScpHost            = $cfg.ScpHost
        ScpUser            = $cfg.ScpUser
        ScpRemoteDirectory = $cfg.ScpRemoteDirectory
        ScpPort            = $cfg.ScpPort
        ScpIdentityFile    = $cfg.ScpIdentityFile
        ScpKnownHostsFile  = $cfg.ScpKnownHostsFile
        LogDirectory       = $cfg.LogDirectory
        TargetUsername     = $cfg.TargetUsername
    }

    Write-ScpCopyLine ''
    Write-ScpCopyLine 'Step 1b: outbound SCP firewall + TCP reachability' -ForegroundColor Cyan
    $fw = Invoke-ScpOutboundFirewallReconcile `
        -RemoteHost ([string]$cfg.ScpHost) `
        -RemotePort ([int]$cfg.ScpPort) `
        -ConfigPath ([string]$cfg.ConfigPath)
    Write-Check -Name 'SCP-Allow firewall' -Ok $fw.Ok -Status $(if ($fw.Ok) { 'OK' } else { 'WARN' }) `
        -Detail $fw.Detail

    $tcpOk = $false
    $tcpDetail = ''
    for ($tcpTry = 1; $tcpTry -le 3; $tcpTry++) {
        $tcp = Test-ScpCopyTcpEndpoint -HostName ([string]$cfg.ScpHost) -Port ([int]$cfg.ScpPort) -TimeoutMs 8000
        $tcpDetail = $tcp.Detail
        if ($tcp.Ok) {
            $tcpOk = $true
            break
        }
        Write-ScpCopyLine (
            "TCP {0}:{1} not reachable (try {2}/3): {3}" -f `
                $cfg.ScpHost, $cfg.ScpPort, $tcpTry, $tcp.Detail) -ForegroundColor Yellow
        if ($tcpTry -lt 3) {
            Start-Sleep -Seconds 5
        }
    }
    Write-Check -Name ("TCP {0}:{1}" -f $cfg.ScpHost, $cfg.ScpPort) -Ok $tcpOk -Detail $tcpDetail
    if (-not $tcpOk) {
        Write-ScpCopyLine ''
        Write-ScpCopyLine 'RESULT: remote host:port not reachable; scp not attempted.' -ForegroundColor Red
        Write-ScpCopyLine (
            "Check that {0} is up on the LAN, SSH is listening on port {1}, and " +
            "run .\scripts\Allow-ScpOutboundFirewall.ps1 elevated if outbound SSH is blocked." -f `
                $cfg.ScpHost, $cfg.ScpPort) -ForegroundColor Yellow
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
        $failMsg = ("scp preflight failed: TCP {0}:{1} not reachable after 3 tries. {2}" -f `
                $cfg.ScpHost, $cfg.ScpPort, $tcpDetail)
        $null = Write-FatalError -Message $failMsg -Context 'Copy-LogsViaScp TCP preflight failed' `
            -Source 'Copy-LogsViaScp' -NoThrow
        exit 1
    }

    Write-ScpCopyLine ''
    Write-ScpCopyLine 'Step 2: select files to copy' -ForegroundColor Cyan
    $fileList = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ScpManualSourceFiles -Config $runtimeCfg -ErrorLogPath (Get-ErrorLogPath))) {
        if (-not [string]::IsNullOrWhiteSpace([string]$f)) {
            $fileList.Add([string]$f)
        }
    }
    # Always stage raw History DBs (every log-history-op-* + log-history-ch-*).
    # Important: wrap with @() first; do NOT pipe the bare return into
    # Where-Object (a single path string is enumerated as characters in WinPS).
    $bHistoryStaged = @(New-ScpBHistoryUploadFiles -TargetUsername ([string]$cfg.TargetUsername))
    $bHistoryStaged = @($bHistoryStaged | Where-Object {
            -not [string]::IsNullOrWhiteSpace([string]$_) -and (Test-Path -LiteralPath ([string]$_))
        })
    $bHistoryOpStaged = @($bHistoryStaged | Where-Object {
            $leaf = Split-Path -Leaf ([string]$_)
            ($leaf -eq 'log-history-op') -or ($leaf -like 'log-history-op-*')
        })
    $bHistoryChStaged = @($bHistoryStaged | Where-Object {
            (Split-Path -Leaf ([string]$_)) -like 'log-history-ch-*'
        })
    if ($bHistoryStaged.Count -gt 0) {
        foreach ($staged in $bHistoryStaged) {
            $fileList.Add([string]$staged)
        }
        Write-Check -Name 'BHistory (raw log-history-*)' -Ok $true -Detail ($bHistoryStaged -join '; ')
        Write-Check -Name 'BHistory op (log-history-op-*)' -Ok ($bHistoryOpStaged.Count -gt 0) -Detail $(
            if ($bHistoryOpStaged.Count -gt 0) {
                ("{0} file(s): {1}" -f $bHistoryOpStaged.Count, (
                    ($bHistoryOpStaged | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
            }
            else {
                'none staged (no op profile History found)'
            }
        )
        Write-Check -Name 'BHistory ch (log-history-ch-*)' -Ok ($bHistoryChStaged.Count -gt 0) -Detail $(
            if ($bHistoryChStaged.Count -gt 0) {
                ("{0} file(s): {1}" -f $bHistoryChStaged.Count, (
                    ($bHistoryChStaged | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))
            }
            else {
                'none staged (no ch profile History found)'
            }
        )
    }
    else {
        $bhDetail = if ([string]::IsNullOrWhiteSpace([string]$cfg.TargetUsername)) {
            'not found (TargetUsername empty; preferred History paths missing/unreadable)'
        }
        else {
            "not found or unreadable for '{0}'" -f $cfg.TargetUsername
        }
        Write-Check -Name 'BHistory (raw log-history-*)' -Ok $true -Status WARN -Detail $bhDetail
        Write-Check -Name 'BHistory op (log-history-op-*)' -Ok $true -Status WARN -Detail 'none staged'
        Write-Check -Name 'BHistory ch (log-history-ch-*)' -Ok $true -Status WARN -Detail 'none staged'
    }
    $files = @($fileList | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
    if ($files.Count -eq 0) {
        Write-Check -Name 'Files selected' -Ok $false -Detail 'none found under LogDirectory / error log paths'
        Write-ScpCopyLine ''
        Write-ScpCopyLine 'RESULT: no files to copy.' -ForegroundColor Yellow
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
        exit 1
    }

    Write-Check -Name 'Files selected' -Ok $true -Detail ("{0} file(s)" -f $files.Count)
    foreach ($f in $files) {
        Write-ScpCopyLine ("  - {0}" -f $f) -ForegroundColor DarkGray
    }

    Write-ScpCopyLine ''
    Write-ScpCopyLine 'Step 3: scp copy (-v)' -ForegroundColor Cyan
    $copyResult = Invoke-ScpCopyFiles -Config $runtimeCfg -Files $files
    $ok = -not (Test-ScpCopyFailed -ExitCode $copyResult.ExitCode `
            -StdErr ([string]$copyResult.StdErr) -TimedOut ([bool]$copyResult.TimedOut))
    Write-Check -Name 'scp exit code' -Ok $ok -Detail ("{0} -> {1}" -f $copyResult.ExitCode, $copyResult.RemoteTarget)

    # scp -v writes progress/file names to stderr; always show it.
    if (-not [string]::IsNullOrWhiteSpace($copyResult.StdErr)) {
        Write-ScpCopyLine '--- scp stderr (-v) ---' -ForegroundColor DarkGray
        Write-ScpCopyLine $copyResult.StdErr.TrimEnd() -ForegroundColor DarkGray
    }
    if (-not [string]::IsNullOrWhiteSpace($copyResult.StdOut)) {
        Write-ScpCopyLine '--- scp stdout ---' -ForegroundColor DarkGray
        Write-ScpCopyLine $copyResult.StdOut.TrimEnd() -ForegroundColor DarkGray
    }

    if (-not $ok) {
        Write-ScpCopyLine ''
        Write-ScpCopyLine 'RESULT: SCP copy failed.' -ForegroundColor Red
        $connectFail = $false
        if (Get-Command Test-ScpConnectFailure -ErrorAction SilentlyContinue) {
            $connectFail = [bool](Test-ScpConnectFailure -StdErr ([string]$copyResult.StdErr))
        }
        if ($connectFail) {
            Write-ScpCopyLine ''
            Write-ScpCopyLine (
                "SSH connect to {0}:{1} failed (timeout/refused/unreachable)." -f `
                    $cfg.ScpHost, $cfg.ScpPort) -ForegroundColor Yellow
            Write-ScpCopyLine 'Confirm the remote is up on the LAN and SSH is listening.' -ForegroundColor Yellow
            Write-ScpCopyLine 'If outbound SSH is blocked, run elevated:' -ForegroundColor Yellow
            Write-ScpCopyLine (
                "  .\scripts\Allow-ScpOutboundFirewall.ps1 -RemoteHost {0} -RemotePort {1}" -f `
                    $cfg.ScpHost, $cfg.ScpPort) -ForegroundColor Yellow
        }
        elseif (Test-ScpAuthFailure -StdErr ([string]$copyResult.StdErr)) {
            $pub = Get-ScpPublicKeyText -IdentityPath $cfg.ScpIdentityFile
            Write-ScpCopyLine ''
            Write-ScpCopyLine 'Public key auth / private key load failed. If Load key Permission denied,' -ForegroundColor Yellow
            Write-ScpCopyLine 'the identity is SYSTEM-only (monitor ACL); this script uses a TEMP copy.' -ForegroundColor Yellow
            Write-ScpCopyLine 'If the remote rejected the key, append this line to remote authorized_keys:' -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($pub)) {
                Write-ScpCopyLine $pub -ForegroundColor Yellow
            }
            else {
                Write-ScpCopyLine ("(could not read public key; check {0}.pub)" -f $cfg.ScpIdentityFile) -ForegroundColor Yellow
            }
        }
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
        $failMsg = ("scp failed (exit {0}). target={1}; files={2}`r`n{3}" -f `
                $copyResult.ExitCode, $copyResult.RemoteTarget, ($files -join '; '),
            ([string]$copyResult.StdErr).Trim())
        $null = Write-FatalError -Message $failMsg -Context 'Copy-LogsViaScp SCP failed' `
            -Source 'Copy-LogsViaScp' -NoThrow
        exit 1
    }

    Write-ScpCopyLine ''
    Write-ScpCopyLine 'RESULT: SCP copy succeeded.' -ForegroundColor Green
    Write-ScpCopyLine ("Uploaded {0} file(s) to {1}" -f $files.Count, $copyResult.RemoteTarget)

    $clearedLogs = @(Reset-LoginTimeLoggerOperationalLogs `
            -ErrorLogPath (Get-ErrorLogPath) `
            -LogDirectory ([string]$cfg.LogDirectory))
    if ($clearedLogs.Count -gt 0) {
        Write-ScpCopyLine ("Reset log file(s): {0}" -f ($clearedLogs -join '; ')) -ForegroundColor DarkGray
    }

    Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Cyan
    exit 0
}
catch {
    if ([string]::IsNullOrWhiteSpace($script:CopyLogPath)) {
        try {
            $null = Initialize-ScpCopyLog -LogPath $LogPath -AdministratorProfile $env:USERPROFILE
        }
        catch { }
    }
    Write-ScpCopyLine ''
    Write-ScpCopyLine ("RESULT: ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
    if (-not [string]::IsNullOrWhiteSpace($script:CopyLogPath)) {
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
    }
    $null = Write-FatalError -ErrorRecord $_ -Context 'Copy-LogsViaScp.ps1 failed' -Source 'Copy-LogsViaScp' -NoThrow
    exit 1
}
finally {
    foreach ($staged in @($bHistoryStaged)) {
        if (-not [string]::IsNullOrWhiteSpace([string]$staged) -and
            (Test-Path -LiteralPath ([string]$staged))) {
            Remove-Item -LiteralPath ([string]$staged) -Force -ErrorAction SilentlyContinue
        }
    }
}
