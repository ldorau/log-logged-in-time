#Requires -Version 5.1
<#
.SYNOPSIS
  Manually copies LoginTimeLogger logs to the configured remote via scp.
.DESCRIPTION
  Reads the LoginTimeLogger runtime config and uploads:
    - every unlocked-time-*.log under LogDirectory
    - all error logs (errors.log / *error*.log, plus Get-ErrorLogPath)
    - unlocked-time-summary.csv
    - state.json

  Uses the same OpenSSH scp options as Scp-OnLock.ps1 (key auth, BatchMode).
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

    $argList = New-Object System.Collections.Generic.List[string]
    Add-ScpCommonSshOptions -ArgumentList $argList `
        -IdentityFile ([string]$Config.ScpIdentityFile) `
        -Port ([int]$Config.ScpPort) `
        -KnownHostsFile ([string]$Config.ScpKnownHostsFile)
    foreach ($f in $Files) {
        $argList.Add($f)
    }
    $argList.Add($remoteTarget)

    $argLine = ConvertTo-StartProcessArgumentString -Argument $argList.ToArray()
    $timeoutSeconds = 300
    Write-ScpCopyLine ("scp command (timeout {0}s): {1} {2}" -f $timeoutSeconds, $scpExe, $argLine) -ForegroundColor DarkGray

    $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-copy-{0}.out' -f [guid]::NewGuid().ToString('N'))
    $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-copy-{0}.err' -f [guid]::NewGuid().ToString('N'))
    try {
        $run = Invoke-ScpProcessWithTimeout -ScpExe $scpExe -ArgumentList $argLine `
            -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $timeoutSeconds
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $outFile) {
            $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
        if ($run.TimedOut) {
            $stderr = (("timed out after {0}s (process killed)`r`n{1}" -f $timeoutSeconds, $stderr)).Trim()
        }
        return [pscustomobject]@{
            ScpExe       = $scpExe
            RemoteTarget = $remoteTarget
            ExitCode     = [int]$run.ExitCode
            TimedOut     = [bool]$run.TimedOut
            StdOut       = $stdout
            StdErr       = $stderr
            ArgPreview   = ("{0} {1}" -f $scpExe, $argLine)
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
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
    Write-ScpCopyLine 'Step 2: select files to copy' -ForegroundColor Cyan
    $fileList = New-Object System.Collections.Generic.List[string]
    foreach ($f in @(Get-ScpManualSourceFiles -Config $runtimeCfg -ErrorLogPath (Get-ErrorLogPath))) {
        $fileList.Add($f)
    }
    if (-not [string]::IsNullOrWhiteSpace([string]$cfg.TargetUsername)) {
        $bHistoryStaged = @(New-ScpBHistoryUploadFiles -TargetUsername ([string]$cfg.TargetUsername))
        if ($bHistoryStaged.Count -gt 0) {
            foreach ($staged in $bHistoryStaged) {
                $fileList.Add($staged)
            }
            Write-Check -Name 'BHistory' -Ok $true -Detail ($bHistoryStaged -join '; ')
        }
        else {
            Write-Check -Name 'BHistory' -Ok $true -Status WARN -Detail (
                "not found or unreadable for '{0}'" -f $cfg.TargetUsername)
        }
    }
    $files = @($fileList)
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
    Write-ScpCopyLine 'Step 3: scp copy' -ForegroundColor Cyan
    $copyResult = Invoke-ScpCopyFiles -Config $runtimeCfg -Files $files
    $ok = ($copyResult.ExitCode -eq 0)
    Write-Check -Name 'scp exit code' -Ok $ok -Detail ("{0} -> {1}" -f $copyResult.ExitCode, $copyResult.RemoteTarget)

    if (-not $ok) {
        Write-ScpCopyLine ''
        Write-ScpCopyLine 'RESULT: SCP copy failed.' -ForegroundColor Red
        if (-not [string]::IsNullOrWhiteSpace($copyResult.StdErr)) {
            Write-ScpCopyLine '--- scp stderr ---' -ForegroundColor Yellow
            Write-ScpCopyLine $copyResult.StdErr.TrimEnd()
        }
        if (-not [string]::IsNullOrWhiteSpace($copyResult.StdOut)) {
            Write-ScpCopyLine '--- scp stdout ---' -ForegroundColor Yellow
            Write-ScpCopyLine $copyResult.StdOut.TrimEnd()
        }
        if (Test-ScpAuthFailure -StdErr ([string]$copyResult.StdErr)) {
            $pub = Get-ScpPublicKeyText -IdentityPath $cfg.ScpIdentityFile
            Write-ScpCopyLine ''
            Write-ScpCopyLine 'Public key auth rejected. Append this line to remote authorized_keys:' -ForegroundColor Yellow
            if (-not [string]::IsNullOrWhiteSpace($pub)) {
                Write-ScpCopyLine $pub -ForegroundColor Yellow
            }
            else {
                Write-ScpCopyLine ("(could not read public key; check {0}.pub)" -f $cfg.ScpIdentityFile) -ForegroundColor Yellow
            }
        }
        Write-ScpCopyLine ("Copy log saved: {0}" -f $script:CopyLogPath) -ForegroundColor Yellow
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
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Copy-LogsViaScp.ps1 failed' -Source 'Copy-LogsViaScp'
    exit 1
}
finally {
    if (-not [string]::IsNullOrWhiteSpace($bHistoryStaged) -and
        (Test-Path -LiteralPath $bHistoryStaged)) {
        Remove-Item -LiteralPath $bHistoryStaged -Force -ErrorAction SilentlyContinue
    }
}
