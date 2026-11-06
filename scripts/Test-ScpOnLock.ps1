#Requires -Version 5.1
<#
.SYNOPSIS
  Tests whether SCP-on-lock log copy to the remote host works.
.DESCRIPTION
  Reads the LoginTimeLogger runtime config, validates SCP settings, then
  copies today's unlocked-time log and errors.log (or a small probe file)
  using the same OpenSSH scp options as Scp-OnLock.ps1.

  On failure, prints debugging details (scp path, identity, target, exit
  code, stdout/stderr, connectivity hints).

  All screen output is also appended to a log file (see -LogPath).

.PARAMETER ConfigPath
  Runtime config JSON. Default: from LoginTimeLogger scheduled task.
.PARAMETER Force
  Run the copy even when ScpOnLockEnabled is false (still requires host/user/
  directory/identity in config).
.PARAMETER ProbeOnly
  Do not use real logs; create and upload a temporary probe file only.
.PARAMETER GenerateIdentity
  If the configured ScpIdentityFile is missing, generate an ed25519 key pair
  (and empty known_hosts) then print the public key for remote authorized_keys.
.PARAMETER LogPath
  Output log file. Default:
  <AdministratorProfile>\LoginTimeLogger\scp-on-lock-test-yyyyMMdd-HHmmss.log
.EXAMPLE
  .\scripts\Test-ScpOnLock.ps1
.EXAMPLE
  .\scripts\Test-ScpOnLock.ps1 -Force -ProbeOnly
.EXAMPLE
  .\scripts\Test-ScpOnLock.ps1 -GenerateIdentity -Force -ProbeOnly
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [switch]$Force,
    [switch]$ProbeOnly,
    [switch]$GenerateIdentity,
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

$script:TestLogPath = $null

function Initialize-ScpTestLog {
    param(
        [string]$LogPath,
        [string]$AdministratorProfile
    )

    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        $script:TestLogPath = $LogPath
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
        $script:TestLogPath = Join-Path $dir ('scp-on-lock-test-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))
    }

    $logDir = Split-Path -Parent $script:TestLogPath
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and -not (Test-Path -LiteralPath $logDir)) {
        New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    }

    $header = @(
        ('=== Test-ScpOnLock log started {0:yyyy-MM-dd HH:mm:ss} ===' -f (Get-Date))
        ('Computer={0}; User={1}' -f $env:COMPUTERNAME, $env:USERNAME)
        ''
    ) -join [Environment]::NewLine
    Set-Content -LiteralPath $script:TestLogPath -Value $header -Encoding UTF8
    return $script:TestLogPath
}

function Write-ScpTestLine {
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

    if (-not [string]::IsNullOrWhiteSpace($script:TestLogPath)) {
        $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
        try {
            Add-Content -LiteralPath $script:TestLogPath -Value $line -Encoding UTF8
        }
        catch {
            # Screen output already succeeded; do not fail the test on log I/O.
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
        Write-ScpTestLine ("  [{0}] {1} - {2}" -f $Status, $Name, $Detail) -ForegroundColor $color
    }
    else {
        Write-ScpTestLine ("  [{0}] {1}" -f $Status, $Name) -ForegroundColor $color
    }
}

function Resolve-TestConfigPath {
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
  .\scripts\Test-ScpOnLock.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
"@
}

function Get-ScpConfigObject {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $adminProfile = [string]$raw.AdministratorProfile
    if ([string]::IsNullOrWhiteSpace($adminProfile)) {
        $adminProfile = $env:USERPROFILE
    }

    $identity = [string]$raw.ScpIdentityFile
    if ([string]::IsNullOrWhiteSpace($identity)) {
        $identity = Join-Path $adminProfile 'LoginTimeLogger\ssh\id_ed25519'
    }
    $knownHosts = [string]$raw.ScpKnownHostsFile
    if ([string]::IsNullOrWhiteSpace($knownHosts)) {
        $knownHosts = Join-Path $adminProfile 'LoginTimeLogger\ssh\known_hosts'
    }

    $logDirectory = [string]$raw.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path $adminProfile 'LoginTimeLogs'
    }

    $port = 22
    if ($null -ne $raw.ScpPort -and [int]$raw.ScpPort -gt 0) {
        $port = [int]$raw.ScpPort
    }

    return [pscustomobject]@{
        ConfigPath           = $Path
        ScpOnLockEnabled     = [bool]$raw.ScpOnLockEnabled
        ScpHost              = [string]$raw.ScpHost
        ScpUser              = [string]$raw.ScpUser
        ScpRemoteDirectory   = [string]$raw.ScpRemoteDirectory
        ScpPort              = $port
        ScpIdentityFile      = $identity
        ScpKnownHostsFile    = $knownHosts
        AdministratorProfile = $adminProfile
        LogDirectory         = $logDirectory
    }
}

function Get-FileDebugInfo {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return '(empty path)'
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        return "missing: $Path"
    }
    try {
        $item = Get-Item -LiteralPath $Path -Force
        $aclSummary = ''
        try {
            $acl = Get-Acl -LiteralPath $Path
            $aclSummary = ($acl.Access | ForEach-Object {
                    '{0}:{1}' -f $_.IdentityReference, $_.FileSystemRights
                }) -join '; '
        }
        catch {
            $aclSummary = "(ACL unreadable: $($_.Exception.Message))"
        }
        return ("exists; Length={0}; LastWrite={1:o}; ACL=[{2}]" -f `
                $item.Length, $item.LastWriteTimeUtc, $aclSummary)
    }
    catch {
        return ("present but unreadable: {0}" -f $_.Exception.Message)
    }
}

function Test-TcpEndpoint {
    param(
        [string]$HostName,
        [Parameter(Mandatory)][int]$Port
    )
    if ([string]::IsNullOrWhiteSpace($HostName)) {
        return [pscustomobject]@{
            Ok     = $false
            Detail = 'HostName is empty; TCP check skipped'
        }
    }
    try {
        $tnc = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue -ErrorAction Stop
        return [pscustomobject]@{
            Ok     = [bool]$tnc.TcpTestSucceeded
            Detail = ("TcpTestSucceeded={0}; PingSucceeded={1}" -f $tnc.TcpTestSucceeded, $tnc.PingSucceeded)
        }
    }
    catch {
        return [pscustomobject]@{
            Ok     = $false
            Detail = $_.Exception.Message
        }
    }
}

function Invoke-ScpCopyForTest {
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
    $argList.Add('-i')
    $argList.Add([string]$Config.ScpIdentityFile)
    $argList.Add('-P')
    $argList.Add("$([int]$Config.ScpPort)")
    $argList.Add('-o')
    $argList.Add('BatchMode=yes')
    $argList.Add('-o')
    $argList.Add('IdentitiesOnly=yes')
    $argList.Add('-o')
    $argList.Add('PreferredAuthentications=publickey')
    $argList.Add('-o')
    $argList.Add('StrictHostKeyChecking=accept-new')
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.ScpKnownHostsFile)) {
        $argList.Add('-o')
        $argList.Add(('UserKnownHostsFile={0}' -f $Config.ScpKnownHostsFile))
    }
    $argList.Add('-o')
    $argList.Add('ConnectTimeout=20')
    $argList.Add('-v')
    foreach ($f in $Files) {
        $argList.Add($f)
    }
    $argList.Add($remoteTarget)

    $argLine = ConvertTo-StartProcessArgumentString -Argument $argList.ToArray()
    # Safe command preview: show identity path, not key contents.
    Write-ScpTestLine ("scp command: {0} {1}" -f $scpExe, $argLine) -ForegroundColor DarkGray

    $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-test-{0}.out' -f [guid]::NewGuid().ToString('N'))
    $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-test-{0}.err' -f [guid]::NewGuid().ToString('N'))
    try {
        $proc = Start-Process -FilePath $scpExe -ArgumentList $argLine `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $outFile -RedirectStandardError $errFile
        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $outFile) {
            $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
        return [pscustomobject]@{
            ScpExe       = $scpExe
            RemoteTarget = $remoteTarget
            ExitCode     = [int]$proc.ExitCode
            StdOut       = $stdout
            StdErr       = $stderr
            ArgPreview   = ("{0} {1}" -f $scpExe, $argLine)
        }
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Write-FailureDebug {
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ScpExe,
        [object]$CopyResult,
        [string[]]$Files,
        [string]$Extra = ''
    )

    Write-ScpTestLine ''
    Write-ScpTestLine '=== DEBUG (SCP-on-lock test failed) ===' -ForegroundColor Yellow
    Write-ScpTestLine ("ConfigPath:     {0}" -f $Config.ConfigPath)
    Write-ScpTestLine ("ScpOnLockEnabled: {0}" -f $Config.ScpOnLockEnabled)
    Write-ScpTestLine ("Host:           {0}" -f $Config.ScpHost)
    Write-ScpTestLine ("User:           {0}" -f $Config.ScpUser)
    Write-ScpTestLine ("RemoteDir:      {0}" -f $Config.ScpRemoteDirectory)
    Write-ScpTestLine ("Port:           {0}" -f $Config.ScpPort)
    Write-ScpTestLine ("IdentityFile:   {0}" -f (Get-FileDebugInfo -Path $Config.ScpIdentityFile))
    Write-ScpTestLine ("KnownHosts:     {0}" -f (Get-FileDebugInfo -Path $Config.ScpKnownHostsFile))
    Write-ScpTestLine ("scp.exe:        {0}" -f $(if ($ScpExe) { $ScpExe } else { '(not found)' }))
    Write-ScpTestLine ("Current user:   {0}" -f ([Security.Principal.WindowsIdentity]::GetCurrent().Name))
    Write-ScpTestLine ("Is elevated:    {0}" -f ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))

    if ($Files) {
        Write-ScpTestLine 'Local files:'
        foreach ($f in $Files) {
            Write-ScpTestLine ("  - {0}" -f (Get-FileDebugInfo -Path $f))
        }
    }

    if (-not [string]::IsNullOrWhiteSpace([string]$Config.ScpHost)) {
        $tcp = Test-TcpEndpoint -HostName $Config.ScpHost -Port ([int]$Config.ScpPort)
        Write-ScpTestLine ("TCP {0}:{1}:  {2} ({3})" -f $Config.ScpHost, $Config.ScpPort, $(if ($tcp.Ok) { 'OK' } else { 'FAIL' }), $tcp.Detail)
    }
    else {
        Write-ScpTestLine 'TCP check:       skipped (ScpHost empty)'
    }

    if ($CopyResult) {
        Write-ScpTestLine ("scp exit code:  {0}" -f $CopyResult.ExitCode)
        Write-ScpTestLine ("scp target:     {0}" -f $CopyResult.RemoteTarget)
        Write-ScpTestLine ("scp cmdline:    {0}" -f $CopyResult.ArgPreview)
        if (-not [string]::IsNullOrWhiteSpace($CopyResult.StdOut)) {
            Write-ScpTestLine '--- scp stdout ---'
            Write-ScpTestLine $CopyResult.StdOut.TrimEnd()
        }
        if (-not [string]::IsNullOrWhiteSpace($CopyResult.StdErr)) {
            Write-ScpTestLine '--- scp stderr (includes -v) ---'
            Write-ScpTestLine $CopyResult.StdErr.TrimEnd()
        }
    }

    if ($Extra) {
        Write-ScpTestLine ("Extra:          {0}" -f $Extra)
    }

    $stderrText = ''
    if ($CopyResult -and -not [string]::IsNullOrWhiteSpace([string]$CopyResult.StdErr)) {
        $stderrText = [string]$CopyResult.StdErr
    }
    $authFailed = Test-ScpAuthFailure -StdErr $stderrText
    if ($authFailed -and -not [string]::IsNullOrWhiteSpace([string]$Config.ScpIdentityFile)) {
        $pub = Get-ScpPublicKeyText -IdentityPath $Config.ScpIdentityFile
        Write-ScpTestLine ''
        Write-ScpTestLine '=== PUBLIC KEY AUTH REJECTED ===' -ForegroundColor Red
        Write-ScpTestLine ("The remote host accepted the TCP connection but rejected key '{0}'." -f $Config.ScpIdentityFile)
        Write-ScpTestLine ("Append the following single line to ~{0}/.ssh/authorized_keys on {1}:" -f $Config.ScpUser, $Config.ScpHost) -ForegroundColor Yellow
        if (-not [string]::IsNullOrWhiteSpace($pub)) {
            Write-ScpTestLine $pub -ForegroundColor Yellow
        }
        else {
            Write-ScpTestLine ("(could not read public key; check {0}.pub)" -f $Config.ScpIdentityFile) -ForegroundColor Yellow
        }
        Write-ScpTestLine 'On the remote host (example):' -ForegroundColor DarkGray
        Write-ScpTestLine '  mkdir -p ~/.ssh && chmod 700 ~/.ssh' -ForegroundColor DarkGray
        Write-ScpTestLine '  # paste the public key line into ~/.ssh/authorized_keys then:' -ForegroundColor DarkGray
        Write-ScpTestLine '  chmod 600 ~/.ssh/authorized_keys' -ForegroundColor DarkGray
    }

    Write-ScpTestLine ''
    Write-ScpTestLine 'Hints:' -ForegroundColor DarkGray
    Write-ScpTestLine '  - Public key for ScpIdentityFile must be in remote authorized_keys for ScpUser.' -ForegroundColor DarkGray
    Write-ScpTestLine '  - Missing local key: re-run Install, or .\scripts\Test-ScpOnLock.ps1 -GenerateIdentity' -ForegroundColor DarkGray
    Write-ScpTestLine '  - ScpRemoteDirectory must exist and be writable by ScpUser.' -ForegroundColor DarkGray
    Write-ScpTestLine '  - Monitor runs as SYSTEM: identity ACL must allow SYSTEM read (reinstall/set ACL if needed).' -ForegroundColor DarkGray
    Write-ScpTestLine '  - BatchMode=yes means password prompts fail; key auth only.' -ForegroundColor DarkGray
    Write-ScpTestLine '  - Firewall/DNS must allow outbound TCP to ScpHost:ScpPort.' -ForegroundColor DarkGray
}

# --- main ---
$probePath = $null
$copyResult = $null
$files = @()

try {
    $null = Initialize-ErrorLog -ConfigPath (Join-Path $repoRoot 'config\config.json')

    $resolvedConfigPath = Resolve-TestConfigPath -ConfigPath $ConfigPath
    $cfg = Get-ScpConfigObject -Path $resolvedConfigPath
    if (-not [string]::IsNullOrWhiteSpace($cfg.AdministratorProfile)) {
        $null = Initialize-ErrorLog -AdministratorProfile $cfg.AdministratorProfile
    }

    $null = Initialize-ScpTestLog -LogPath $LogPath -AdministratorProfile $cfg.AdministratorProfile

    Write-ScpTestLine '=== Test-ScpOnLock ===' -ForegroundColor Cyan
    Write-ScpTestLine ("Config: {0}" -f $cfg.ConfigPath)
    Write-ScpTestLine ("Error log file: {0}" -f (Get-ErrorLogPath))
    Write-ScpTestLine ("Test log file:  {0}" -f $script:TestLogPath)
    Write-ScpTestLine ''

    Write-ScpTestLine 'Step 1: configuration checks' -ForegroundColor Cyan
    Write-Check -Name 'ScpOnLockEnabled' -Ok ($cfg.ScpOnLockEnabled -or $Force) -Detail $(
        if ($cfg.ScpOnLockEnabled) { 'true' }
        elseif ($Force) { 'false (continuing because -Force)' }
        else { 'false (enable in config or pass -Force)' }
    )
    Write-Check -Name 'ScpHost' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpHost)) -Detail $(if ($cfg.ScpHost) { $cfg.ScpHost } else { 'empty' })
    Write-Check -Name 'ScpUser' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpUser)) -Detail $(if ($cfg.ScpUser) { $cfg.ScpUser } else { 'empty' })
    Write-Check -Name 'ScpRemoteDirectory' -Ok (-not [string]::IsNullOrWhiteSpace($cfg.ScpRemoteDirectory)) -Detail $(if ($cfg.ScpRemoteDirectory) { $cfg.ScpRemoteDirectory } else { 'empty' })
    Write-Check -Name 'ScpPort' -Ok ($cfg.ScpPort -gt 0) -Detail "$($cfg.ScpPort)"

    if ($GenerateIdentity -and -not (Test-Path -LiteralPath $cfg.ScpIdentityFile)) {
        Write-ScpTestLine ''
        Write-ScpTestLine ("Generating SCP identity at {0} ..." -f $cfg.ScpIdentityFile) -ForegroundColor Cyan
        $generated = New-ScpIdentityKeyFile -IdentityPath $cfg.ScpIdentityFile -KnownHostsPath $cfg.ScpKnownHostsFile
        if ($generated.Created) {
            Write-Check -Name 'ScpIdentityFile generated' -Ok $true -Detail $generated.IdentityPath
            if (-not [string]::IsNullOrWhiteSpace($generated.PublicKey)) {
                Write-ScpTestLine 'Add this public key to the remote user authorized_keys:' -ForegroundColor Yellow
                Write-ScpTestLine $generated.PublicKey -ForegroundColor Yellow
            }
        }
        else {
            Write-Check -Name 'ScpIdentityFile exists' -Ok $true -Detail ('already present: {0}' -f $generated.IdentityPath)
        }
    }

    $identityExists = Test-Path -LiteralPath $cfg.ScpIdentityFile
    Write-Check -Name 'ScpIdentityFile exists' -Ok $identityExists -Detail $(
        if ($identityExists) { $cfg.ScpIdentityFile }
        else { "missing: $($cfg.ScpIdentityFile) (re-run Install or pass -GenerateIdentity)" }
    )

    $scpExe = Find-ScpExecutable
    Write-Check -Name 'scp.exe' -Ok (-not [string]::IsNullOrWhiteSpace($scpExe)) -Detail $(if ($scpExe) { $scpExe } else { 'not found' })

    $knownOk = [string]::IsNullOrWhiteSpace($cfg.ScpKnownHostsFile) -or (Test-Path -LiteralPath $cfg.ScpKnownHostsFile)
    if ($knownOk) {
        Write-Check -Name 'ScpKnownHostsFile' -Ok $true -Detail $(
            if ([string]::IsNullOrWhiteSpace($cfg.ScpKnownHostsFile)) { '(not set; OpenSSH default)' }
            else { $cfg.ScpKnownHostsFile }
        )
    }
    else {
        # Missing file is fine with StrictHostKeyChecking=accept-new; OpenSSH creates it on first connect.
        Write-Check -Name 'ScpKnownHostsFile' -Ok $true -Status WARN -Detail (
            "missing: $($cfg.ScpKnownHostsFile) (will accept-new on first connect)")
    }

    $configReady = ($cfg.ScpOnLockEnabled -or $Force) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpHost) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpUser) `
        -and -not [string]::IsNullOrWhiteSpace($cfg.ScpRemoteDirectory) `
        -and $identityExists `
        -and $scpExe

    if (-not $configReady) {
        Write-FailureDebug -Config $cfg -ScpExe $scpExe -Files @() -Extra 'Configuration incomplete; scp not attempted.'
        Write-ScpTestLine ("Test log saved: {0}" -f $script:TestLogPath) -ForegroundColor Yellow
        exit 1
    }

    # Build transferable config object expected by Test-ScpOnLockConfigured / Invoke
    $runtimeCfg = [pscustomobject]@{
        ScpOnLockEnabled   = $true
        ScpHost            = $cfg.ScpHost
        ScpUser            = $cfg.ScpUser
        ScpRemoteDirectory = $cfg.ScpRemoteDirectory
        ScpPort            = $cfg.ScpPort
        ScpIdentityFile    = $cfg.ScpIdentityFile
        ScpKnownHostsFile  = $cfg.ScpKnownHostsFile
        LogDirectory       = $cfg.LogDirectory
    }

    Write-ScpTestLine ''
    Write-ScpTestLine 'Step 2: select files to copy' -ForegroundColor Cyan
    $fileList = New-Object System.Collections.Generic.List[string]
    if ($ProbeOnly) {
        $probePath = Join-Path $env:TEMP ('LoginTimeLogger-scp-probe-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        @(
            'LoginTimeLogger SCP-on-lock probe'
            ('CreatedUtc={0}' -f [datetime]::UtcNow.ToString('o'))
            ('Host={0}' -f $env:COMPUTERNAME)
            ('User={0}' -f $env:USERNAME)
        ) | Set-Content -LiteralPath $probePath -Encoding UTF8
        $fileList.Add($probePath)
        Write-Check -Name 'Probe file' -Ok $true -Detail $probePath
    }
    else {
        $todayLog = Join-Path $cfg.LogDirectory ('unlocked-time-{0:yyyy-MM-dd}.log' -f (Get-Date))
        $errorLog = Get-ErrorLogPath
        $selected = @(Get-ScpOnLockSourceFiles -Config $runtimeCfg -TimeLogPath $todayLog -ErrorLogPath $errorLog)
        foreach ($f in $selected) {
            $fileList.Add($f)
        }
        Write-Check -Name 'Log files selected' -Ok ($fileList.Count -gt 0) -Detail $(
            if ($fileList.Count -gt 0) { ($fileList -join '; ') } else { 'none' })
        if ($fileList.Count -eq 0) {
            $probePath = Join-Path $env:TEMP ('LoginTimeLogger-scp-probe-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            "LoginTimeLogger SCP probe (no logs present yet) $(Get-Date -Format o)" |
                Set-Content -LiteralPath $probePath -Encoding UTF8
            $fileList.Add($probePath)
            Write-Check -Name 'Fallback probe file' -Ok $true -Detail $probePath
        }
    }
    $files = @($fileList)

    Write-ScpTestLine ''
    Write-ScpTestLine 'Step 3: TCP reachability' -ForegroundColor Cyan
    $tcp = Test-TcpEndpoint -HostName $cfg.ScpHost -Port ([int]$cfg.ScpPort)
    Write-Check -Name ("TCP {0}:{1}" -f $cfg.ScpHost, $cfg.ScpPort) -Ok $tcp.Ok -Detail $tcp.Detail
    if (-not $tcp.Ok) {
        Write-FailureDebug -Config $cfg -ScpExe $scpExe -Files $files -Extra 'Host/port not reachable; scp will likely fail.'
        # still attempt scp for full stderr diagnostics
    }

    Write-ScpTestLine ''
    Write-ScpTestLine 'Step 4: scp copy (same options as monitor, plus -v)' -ForegroundColor Cyan
    $copyResult = Invoke-ScpCopyForTest -Config $runtimeCfg -Files $files
    $ok = ($copyResult.ExitCode -eq 0)
    Write-Check -Name 'scp exit code' -Ok $ok -Detail ("{0} -> {1}" -f $copyResult.ExitCode, $copyResult.RemoteTarget)

    if (-not $ok) {
        Write-FailureDebug -Config $cfg -ScpExe $scpExe -CopyResult $copyResult -Files $files
        Write-ScpTestLine ("Test log saved: {0}" -f $script:TestLogPath) -ForegroundColor Yellow
        exit 1
    }

    Write-ScpTestLine ''
    Write-ScpTestLine 'RESULT: SCP-on-lock copy succeeded.' -ForegroundColor Green
    Write-ScpTestLine ("Uploaded {0} file(s) to {1}" -f $files.Count, $copyResult.RemoteTarget)
    Write-ScpTestLine ("Test log saved: {0}" -f $script:TestLogPath) -ForegroundColor Cyan
    exit 0
}
catch {
    # If log was not initialized yet (config resolve failed), fall back to TEMP.
    if ([string]::IsNullOrWhiteSpace($script:TestLogPath)) {
        try {
            $null = Initialize-ScpTestLog -LogPath $LogPath -AdministratorProfile $env:USERPROFILE
        }
        catch { }
    }
    Write-ScpTestLine ''
    Write-ScpTestLine ("RESULT: ERROR - {0}" -f $_.Exception.Message) -ForegroundColor Red
    try {
        if (Get-Variable -Name cfg -Scope Local -ErrorAction SilentlyContinue) {
            Write-FailureDebug -Config $cfg -ScpExe (Find-ScpExecutable) -CopyResult $copyResult -Files $files -Extra $_.Exception.Message
        }
    }
    catch { }
    if (-not [string]::IsNullOrWhiteSpace($script:TestLogPath)) {
        Write-ScpTestLine ("Test log saved: {0}" -f $script:TestLogPath) -ForegroundColor Yellow
    }
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Test-ScpOnLock.ps1 failed' -Source 'Test-ScpOnLock'
    exit 1
}
finally {
    if ($probePath -and (Test-Path -LiteralPath $probePath)) {
        Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
    }
}
