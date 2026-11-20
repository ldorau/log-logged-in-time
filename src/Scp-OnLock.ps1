# SCP helper for LoginTimeLogger (dot-sourced by the monitor).
# On screen lock, copies the two newest unlocked-time-*.log files and error logs.

# BHistory periodic SCP (not configurable).
$script:ScpBHistoryIntervalMinutes = 1
# Remote commands.txt exchange — own 1-minute timer (not tied to heavy BH uploads).
$script:ScpCommandsIntervalMinutes = 1
# StrictMode-safe defaults (Test-ScpOnLock / Copy-LogsViaScp dot-source this file).
$script:LastBHistoryMissingWarnUtc = $null
$script:LastBHistorySourceWriteUtc = $null
$script:LastBHistoryScpSucceeded = $false
# Per staged leaf (log-history-op-<profile> / log-history-ch-<profile>): WriteUtc + Succeeded.
$script:LastBHistoryStateByLeaf = @{}
# Remote commands.txt "reset [[+|-]TIME]" adjustments applied by the monitor poll loop.
# Use ArrayList (not List[object]): @($list[object]) throws ArgumentException under PS 5.1 StrictMode.
$script:PendingCumulativeResets = New-Object System.Collections.ArrayList
# Remote commands.txt "break" — show break dialog + lock on the next monitor poll.
$script:PendingBreakRequested = $false
# Throttle connect-timeout noise (errors.log / email) when the remote is down.
$script:LastScpConnectFailLogUtc = $null
$script:LastScpAllowReconcileUtc = $null
# After SSH connect/banner failures, skip BHistory/lock upload cycles until this UTC time.
# commands.txt exchange does NOT honor this (stays on its 1-minute timer).
$script:ScpConnectBackoffUntilUtc = $null
$script:ScpConnectBackoffMinutes = 10
# Directory of this helper while it is being dot-sourced (src/ under install or repo).
$script:ScpOnLockScriptDir = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($script:ScpOnLockScriptDir) -and $MyInvocation -and $MyInvocation.MyCommand -and
    -not [string]::IsNullOrWhiteSpace([string]$MyInvocation.MyCommand.Path)) {
    $script:ScpOnLockScriptDir = Split-Path -Parent ([string]$MyInvocation.MyCommand.Path)
}

function ConvertFrom-ScpB64Path {
    param([Parameter(Mandatory)][string]$Base64)
    return [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Base64))
}

# Absolute path checked first (preferred Default\History).
$script:ScpBHistoryPreferredAbsolute = ConvertFrom-ScpB64Path `
    'QzpcVXNlcnNccGl0ZXJcQXBwRGF0YVxSb2FtaW5nXE9wZXJhIFNvZnR3YXJlXE9wZXJhIEdYIFN0YWJsZVxEZWZhdWx0XEhpc3Rvcnk='
# Second preferred absolute (Local Default\History).
$script:ScpBHistoryPreferredAbsoluteSecondary = ConvertFrom-ScpB64Path `
    'QzpcVXNlcnNccGl0ZXJcQXBwRGF0YVxMb2NhbFxHb29nbGVcQ2hyb21lXFVzZXIgRGF0YVxEZWZhdWx0XEhpc3Rvcnk='
# Relative paths under AppData\Roaming (order matches discovery preference).
$script:ScpBHistoryRoamingRels = @(
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXERlZmF1bHRcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1hcSGlzdG9yeQ==')
)
# Relative paths under AppData\Local (includes Programs\... installs).
$script:ScpBHistoryLocalRels = @(
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXERlZmF1bHRcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1hcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'UHJvZ3JhbXNcT3BlcmEgR1hccHJvZmlsZVxIaXN0b3J5')
    (ConvertFrom-ScpB64Path 'UHJvZ3JhbXNcT3BlcmEgR1hcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'UHJvZ3JhbXNcT3BlcmEgU29mdHdhcmVcT3BlcmEgR1hccHJvZmlsZVxIaXN0b3J5')
    (ConvertFrom-ScpB64Path 'UHJvZ3JhbXNcT3BlcmEgU29mdHdhcmVcT3BlcmEgR1hcSGlzdG9yeQ==')
)
# Secondary (ch) User Data root under AppData\Local (all profiles scanned for History).
$script:ScpBHistoryChUserDataRel = ConvertFrom-ScpB64Path 'R29vZ2xlXENocm9tZVxVc2VyIERhdGE='
# Primary (op) product roots under AppData\Roaming and AppData\Local (all profiles scanned).
$script:ScpBHistoryOpProductRels = @(
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxl')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1g=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgR1ggU3RhYmxl')
)
# paths relative to a BH install directory.
$script:ScpBHistoryInstallRels = @(
    (ConvertFrom-ScpB64Path 'cHJvZmlsZVxIaXN0b3J5')
    (ConvertFrom-ScpB64Path 'ZGF0YVxwcm9maWxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'VXNlciBEYXRhXERlZmF1bHRcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'VXNlciBEYXRhXFByb2ZpbGUgMVxIaXN0b3J5')
    (ConvertFrom-ScpB64Path 'VXNlciBEYXRhXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'SGlzdG9yeQ==')
)
# Install-dir leaf names under Program Files / Local\Programs.
$script:ScpBHistoryInstallDirLeaves = @(
    (ConvertFrom-ScpB64Path 'T3BlcmEgR1g=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1g=')
)
$script:ScpBHistorySecondaryInstallDirLeaves = @(
    (ConvertFrom-ScpB64Path 'R29vZ2xlXENocm9tZQ==')
    (ConvertFrom-ScpB64Path 'R29vZ2xlIENocm9tZQ==')
)

function Find-ScpExecutable {
    $cmd = Get-Command scp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe')
        (Join-Path $env:SystemRoot 'Sysnative\OpenSSH\scp.exe')
        (Join-Path ${env:ProgramFiles} 'OpenSSH\scp.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Find-SshExecutable {
    $cmd = Get-Command ssh.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe')
        (Join-Path $env:SystemRoot 'Sysnative\OpenSSH\ssh.exe')
        (Join-Path ${env:ProgramFiles} 'OpenSSH\ssh.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    # Prefer sibling of scp.exe when PATH is incomplete under SYSTEM.
    $scp = Find-ScpExecutable
    if (-not [string]::IsNullOrWhiteSpace($scp)) {
        $sibling = Join-Path (Split-Path -Parent $scp) 'ssh.exe'
        if (Test-Path -LiteralPath $sibling) { return $sibling }
    }
    return $null
}

function Find-SshKeygenExecutable {
    $cmd = Get-Command ssh-keygen.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\OpenSSH\ssh-keygen.exe')
        (Join-Path $env:SystemRoot 'Sysnative\OpenSSH\ssh-keygen.exe')
        (Join-Path ${env:ProgramFiles} 'OpenSSH\ssh-keygen.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Protect-ScpPrivateKeyFile {
    <#
      OpenSSH refuses private keys that any non-caller account can read.
      The monitor runs scp as SYSTEM, so the key must be SYSTEM-only
      (admin+Users ACEs cause "UNPROTECTED PRIVATE KEY FILE").
      Uses Set-Acl then icacls so leftover admin (e.g. InWin\dluka) ACEs
      cannot remain after a prior Install as that user.
    #>
    param([Parameter(Mandatory)][string]$IdentityPath)

    if ([string]::IsNullOrWhiteSpace($IdentityPath) -or
        -not (Test-Path -LiteralPath $IdentityPath)) {
        return
    }

    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
    $acl = Get-Acl -LiteralPath $IdentityPath
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        $null = $acl.RemoveAccessRule($rule)
    }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                $sidSystem,
                [System.Security.AccessControl.FileSystemRights]::FullControl,
                [System.Security.AccessControl.AccessControlType]::Allow)))
    Set-Acl -LiteralPath $IdentityPath -AclObject $acl

    # Reinforce with icacls (OpenSSH is picky; Set-Acl alone can leave the
    # creating admin readable on some hosts).
    $icacls = Join-Path $env:SystemRoot 'System32\icacls.exe'
    if (Test-Path -LiteralPath $icacls) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & $icacls $IdentityPath /inheritance:r 2>&1
            $null = & $icacls $IdentityPath /grant:r '*S-1-5-18:(F)' 2>&1
            # Drop every remaining non-SYSTEM allow ACE.
            $acl2 = Get-Acl -LiteralPath $IdentityPath
            foreach ($rule in @($acl2.Access)) {
                try {
                    $sid = $rule.IdentityReference.Translate(
                        [System.Security.Principal.SecurityIdentifier])
                }
                catch {
                    $sid = $null
                }
                if ($null -eq $sid -or $sid.Value -ne 'S-1-5-18') {
                    $null = $acl2.RemoveAccessRule($rule)
                }
            }
            Set-Acl -LiteralPath $IdentityPath -AclObject $acl2
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }
}

function Test-ScpRunningAsLocalSystem {
    try {
        $sid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
        return ($null -ne $sid -and $sid.Value -eq 'S-1-5-18')
    }
    catch {
        return $false
    }
}

function New-ScpIdentityCopyForCurrentUser {
    <#
      Copy the SYSTEM-hardened private key to TEMP with an ACL that only the
      current interactive user can read (OpenSSH requirement). Temporarily
      grants the caller read on the source key, copies, then restores the
      source ACL. Caller must delete the returned path when finished.
      Returns '' on failure. Do not return from inside try/finally (PS 5.1
      can drop that return value).
    #>
    param([Parameter(Mandatory)][string]$IdentityPath)

    if ([string]::IsNullOrWhiteSpace($IdentityPath) -or
        -not (Test-Path -LiteralPath $IdentityPath)) {
        return ''
    }

    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().User
    if ($null -eq $currentUser) {
        return ''
    }

    $tmp = Join-Path $env:TEMP ('LoginTimeLogger-scp-id-' + [guid]::NewGuid().ToString('N'))
    $aclOrig = $null
    $result = ''
    try {
        $aclOrig = Get-Acl -LiteralPath $IdentityPath
        $aclGrant = Get-Acl -LiteralPath $IdentityPath
        $aclGrant.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $currentUser,
                    [System.Security.AccessControl.FileSystemRights]::Read,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -LiteralPath $IdentityPath -AclObject $aclGrant

        Copy-Item -LiteralPath $IdentityPath -Destination $tmp -Force -ErrorAction Stop

        $aclTmp = Get-Acl -LiteralPath $tmp
        $aclTmp.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($aclTmp.Access)) {
            $null = $aclTmp.RemoveAccessRule($rule)
        }
        $aclTmp.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $currentUser,
                    [System.Security.AccessControl.FileSystemRights]::FullControl,
                    [System.Security.AccessControl.AccessControlType]::Allow)))
        Set-Acl -LiteralPath $tmp -AclObject $aclTmp
        $result = $tmp
    }
    catch {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
        $result = ''
    }
    finally {
        if ($null -ne $aclOrig) {
            try {
                Set-Acl -LiteralPath $IdentityPath -AclObject $aclOrig
            }
            catch {
                try { Protect-ScpPrivateKeyFile -IdentityPath $IdentityPath } catch { }
            }
        }
    }
    return $result
}

function New-ScpIdentityKeyFile {
    <#
      Creates an ed25519 private key for SCP-on-lock when missing.
      Also ensures the parent directory and an empty known_hosts sibling exist.
      Returns Created=$false when the private key already exists.
    #>
    param(
        [Parameter(Mandatory)][string]$IdentityPath,
        [string]$KnownHostsPath = '',
        [string]$Comment = 'LoginTimeLogger-scp-on-lock'
    )

    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        throw 'IdentityPath is required.'
    }

    $dir = Split-Path -Parent $IdentityPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    if ([string]::IsNullOrWhiteSpace($KnownHostsPath)) {
        $KnownHostsPath = Join-Path $dir 'known_hosts'
    }
    if (-not (Test-Path -LiteralPath $KnownHostsPath)) {
        $khDir = Split-Path -Parent $KnownHostsPath
        if (-not [string]::IsNullOrWhiteSpace($khDir) -and -not (Test-Path -LiteralPath $khDir)) {
            New-Item -ItemType Directory -Path $khDir -Force | Out-Null
        }
        Set-Content -LiteralPath $KnownHostsPath -Value '' -Encoding ASCII
    }

    $pubPath = "$IdentityPath.pub"
    if (Test-Path -LiteralPath $IdentityPath) {
        Protect-ScpPrivateKeyFile -IdentityPath $IdentityPath
        $pubText = ''
        if (Test-Path -LiteralPath $pubPath) {
            $pubText = ((Get-Content -LiteralPath $pubPath -Raw -ErrorAction SilentlyContinue) + '').Trim()
        }
        return [pscustomobject]@{
            Created        = $false
            IdentityPath   = $IdentityPath
            PublicKeyPath  = $pubPath
            PublicKey      = $pubText
            KnownHostsPath = $KnownHostsPath
        }
    }

    $keygen = Find-SshKeygenExecutable
    if (-not $keygen) {
        throw 'ssh-keygen.exe not found (install OpenSSH Client).'
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    $exitCode = -1
    try {
        # Empty passphrase: Windows OpenSSH wants -N "" (two double-quotes).
        $output = & $keygen -t ed25519 -f $IdentityPath -N '""' -q -C $Comment 2>&1
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    if ($exitCode -ne 0 -or -not (Test-Path -LiteralPath $IdentityPath)) {
        throw ("ssh-keygen failed (exit {0}) creating '{1}': {2}" -f `
                $exitCode, $IdentityPath, (($output | ForEach-Object { "$_" }) -join ' '))
    }

    Protect-ScpPrivateKeyFile -IdentityPath $IdentityPath

    $pubText = ''
    if (Test-Path -LiteralPath $pubPath) {
        $pubText = ((Get-Content -LiteralPath $pubPath -Raw -ErrorAction SilentlyContinue) + '').Trim()
    }

    return [pscustomobject]@{
        Created        = $true
        IdentityPath   = $IdentityPath
        PublicKeyPath  = $pubPath
        PublicKey      = $pubText
        KnownHostsPath = $KnownHostsPath
    }
}

function Get-ScpPublicKeyText {
    <#
      Returns the OpenSSH public key line for an identity file (.pub or derived via ssh-keygen -y).
    #>
    param([Parameter(Mandatory)][string]$IdentityPath)

    if ([string]::IsNullOrWhiteSpace($IdentityPath)) {
        return ''
    }

    $pubPath = "$IdentityPath.pub"
    if (Test-Path -LiteralPath $pubPath) {
        return ((Get-Content -LiteralPath $pubPath -Raw -ErrorAction SilentlyContinue) + '').Trim()
    }

    if (-not (Test-Path -LiteralPath $IdentityPath)) {
        return ''
    }

    $keygen = Find-SshKeygenExecutable
    if (-not $keygen) {
        return ''
    }

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $keygen -y -f $IdentityPath 2>&1
        if ([int]$LASTEXITCODE -ne 0) {
            return ''
        }
        return (("$output") + '').Trim()
    }
    finally {
        $ErrorActionPreference = $prevEap
    }
}

function Test-ScpAuthFailure {
    param([string]$StdErr)

    if ([string]::IsNullOrWhiteSpace($StdErr)) {
        return $false
    }
    return ($StdErr -match '(?i)Permission denied \(publickey') -or
        ($StdErr -match '(?i)No more authentication methods to try') -or
        ($StdErr -match '(?i)Load key .+Permission denied') -or
        ($StdErr -match '(?i)UNPROTECTED PRIVATE KEY')
}

function Get-ScpVerboseExitStatus {
    <#
      Parse "debug1: Exit status N" from scp -v stderr (authoritative when
      Start-Process ExitCode is missing/wrong on Windows).
    #>
    param([string]$StdErr = '')

    if ([string]::IsNullOrWhiteSpace($StdErr)) {
        return $null
    }
    if ($StdErr -match '(?im)debug1:\s*Exit status\s+(\d+)') {
        return [int]$Matches[1]
    }
    if ($StdErr -match '(?im)(?:^|\n)Exit status\s+(\d+)') {
        return [int]$Matches[1]
    }
    return $null
}

function Test-ScpCopyFailed {
    <#
      True when scp failed. Prefer a real process ExitCode (>=0, not the
      Windows -1 quirk) over verbose "Exit status N" — aggregated multi-batch
      stderr can contain an earlier "Exit status 0" and hide a later failure.
      Fall back to verbose status only when ExitCode is null/-1.
    #>
    param(
        [AllowNull()]$ExitCode,
        [string]$StdErr = '',
        [bool]$TimedOut = $false
    )

    if ($TimedOut) { return $true }
    if (Test-ScpAuthFailure -StdErr $StdErr) { return $true }

    if ($null -ne $ExitCode) {
        try {
            $code = [int]$ExitCode
            # -1 = Start-Process / Process quirk (unknown); otherwise trust it.
            if ($code -ne -1) {
                return ($code -ne 0)
            }
        }
        catch { }
    }

    $verboseExit = Get-ScpVerboseExitStatus -StdErr $StdErr
    if ($null -ne $verboseExit) {
        return ($verboseExit -ne 0)
    }

    if ($null -eq $ExitCode) { return $true }
    try {
        return ([int]$ExitCode -ne 0)
    }
    catch {
        return $true
    }
}

function Test-ScpConnectFailure {
    <#
      True when stderr shows the TCP/SSH connect or banner/kex handshake failed
      (timeout, refused, unreachable, getpeername). Distinct from auth failures
      and mid-transfer stalls. TCP can succeed while SSH banner exchange hangs.
    #>
    param([string]$StdErr = '')

    if ([string]::IsNullOrWhiteSpace($StdErr)) {
        return $false
    }
    $s = [string]$StdErr
    return (
        $s -match '(?i)Connection timed out' -or
        $s -match '(?i)Connection refused' -or
        $s -match '(?i)Network is unreachable' -or
        $s -match '(?i)No route to host' -or
        $s -match '(?i)Could not resolve hostname' -or
        $s -match '(?i)connect to .+ port \d+: ' -or
        $s -match '(?i)kex_exchange_identification' -or
        $s -match '(?i)banner exchange' -or
        $s -match '(?i)getpeername failed' -or
        $s -match '(?i)Connection closed by remote host' -or
        $s -match '(?i)Connection reset by peer'
    )
}

function Set-ScpConnectBackoff {
    param([int]$Minutes = 0)

    if ($Minutes -le 0) {
        $Minutes = [int]$script:ScpConnectBackoffMinutes
    }
    if ($Minutes -lt 1) { $Minutes = 10 }
    $script:ScpConnectBackoffUntilUtc = [datetime]::UtcNow.AddMinutes($Minutes)
}

function Clear-ScpConnectBackoff {
    $script:ScpConnectBackoffUntilUtc = $null
}

function Test-ScpConnectBackoffActive {
    if ($script:ScpConnectBackoffUntilUtc -isnot [datetime]) {
        return $false
    }
    if ([datetime]::UtcNow -ge $script:ScpConnectBackoffUntilUtc) {
        $script:ScpConnectBackoffUntilUtc = $null
        return $false
    }
    return $true
}

function Test-ScpSshHandshake {
    <#
      TCP can succeed while SSH banner/kex hangs (seen as getpeername /
      kex_exchange_identification / banner exchange timeouts). Probe with ssh
      BatchMode; auth failure still counts as OK (handshake completed).
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$IdentityFile,
        [string]$KnownHostsFile = '',
        [int]$ConnectTimeoutSeconds = 20
    )

    $sshExe = Find-SshExecutable
    if ([string]::IsNullOrWhiteSpace($sshExe) -or -not (Test-Path -LiteralPath $sshExe)) {
        # No ssh.exe: fall back to TCP-only reachability.
        return (Test-ScpHostPortReachable -HostName $HostName -Port $Port -TimeoutMs 8000)
    }
    if (-not (Test-Path -LiteralPath $IdentityFile)) {
        return $false
    }

    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-i')
    $argList.Add($IdentityFile.Trim())
    $argList.Add('-p')
    $argList.Add("$Port")
    $argList.Add('-o')
    $argList.Add('BatchMode=yes')
    $argList.Add('-o')
    $argList.Add('IdentitiesOnly=yes')
    $argList.Add('-o')
    $argList.Add('PreferredAuthentications=publickey')
    $argList.Add('-o')
    $argList.Add('StrictHostKeyChecking=accept-new')
    if (-not [string]::IsNullOrWhiteSpace($KnownHostsFile)) {
        $argList.Add('-o')
        $argList.Add(('UserKnownHostsFile={0}' -f $KnownHostsFile.Trim()))
    }
    $argList.Add('-o')
    $argList.Add(('ConnectTimeout={0}' -f $ConnectTimeoutSeconds))
    $argList.Add('-o')
    $argList.Add('ServerAliveInterval=5')
    $argList.Add('-o')
    $argList.Add('ServerAliveCountMax=2')
    # -n: stdin from NUL (avoids hang when parent redirects pipes).
    $argList.Add('-n')
    $argList.Add('-v')
    $argList.Add(('{0}@{1}' -f $UserName.Trim(), $HostName.Trim()))
    $argList.Add('exit')

    $outFile = Join-Path $env:TEMP ('LoginTimeLogger-ssh-probe-{0}.out' -f [guid]::NewGuid().ToString('N'))
    $errFile = Join-Path $env:TEMP ('LoginTimeLogger-ssh-probe-{0}.err' -f [guid]::NewGuid().ToString('N'))
    try {
        $argLine = ConvertTo-ScpArgumentLine -Arguments $argList.ToArray()
        $timeoutSec = [Math]::Max(15, $ConnectTimeoutSeconds + 10)
        $run = Invoke-ScpProcessWithTimeout -ScpExe $sshExe -ArgumentList $argLine `
            -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $timeoutSec
        $stderr = ''
        if (Test-Path -LiteralPath $errFile) {
            $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
        }
        if ([bool]$run.TimedOut) {
            return $false
        }
        if (Test-ScpConnectFailure -StdErr "$stderr") {
            return $false
        }
        # Exit 0 = auth+command OK. Non-zero without connect patterns = handshake OK
        # (e.g. auth denied still proves the SSH server answered).
        return $true
    }
    catch {
        return $false
    }
    finally {
        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
    }
}

function Test-ScpHostPortReachable {
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutMs = 5000
    )

    if ([string]::IsNullOrWhiteSpace($HostName) -or $Port -le 0) {
        return $false
    }
    $client = $null
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $ar = $client.BeginConnect($HostName, $Port, $null, $null)
        if (-not $ar.AsyncWaitHandle.WaitOne($TimeoutMs, $false)) {
            try { $client.Close() } catch { }
            return $false
        }
        $client.EndConnect($ar)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $client) {
            try { $client.Close() } catch { }
            try { $client.Dispose() } catch { }
        }
    }
}

function Test-ScpRemoteReady {
    <#
      Reachability for SCP uploads/commands. Do NOT gate on .NET TcpClient —
      it can time out while OpenSSH scp/ssh still works (per-app firewall /
      DualStack). Probe with ssh.exe BatchMode (same stack as scp).
    #>
    param(
        [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][int]$Port,
        [Parameter(Mandatory)][string]$UserName,
        [Parameter(Mandatory)][string]$IdentityFile,
        [string]$KnownHostsFile = '',
        [int]$ConnectTimeoutSeconds = 20,
        $Config = $null
    )

    if ($null -ne $Config) {
        $null = Invoke-ScpOutboundAllowReconcile -Config $Config
    }

    $ok = Test-ScpSshHandshake `
        -HostName $HostName `
        -Port $Port `
        -UserName $UserName `
        -IdentityFile $IdentityFile `
        -KnownHostsFile $KnownHostsFile `
        -ConnectTimeoutSeconds $ConnectTimeoutSeconds
    if ($ok) {
        return $true
    }

    if ($null -ne $Config) {
        $null = Invoke-ScpOutboundAllowReconcile -Config $Config -Force
        Start-Sleep -Seconds 2
    }
    return [bool](Test-ScpSshHandshake `
            -HostName $HostName `
            -Port $Port `
            -UserName $UserName `
            -IdentityFile $IdentityFile `
            -KnownHostsFile $KnownHostsFile `
            -ConnectTimeoutSeconds $ConnectTimeoutSeconds)
}

function Write-ScpConnectFailureThrottled {
    <#
      Log connect failures at most once per ThrottleMinutes (default 15) so a
      down remote does not flood errors.log every 1-minute SCP cycle.
    #>
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Level = 'WARN',
        [int]$ThrottleMinutes = 15
    )

    $now = [datetime]::UtcNow
    $shouldLog = $true
    if ($script:LastScpConnectFailLogUtc -is [datetime]) {
        $shouldLog = (($now - $script:LastScpConnectFailLogUtc).TotalMinutes -ge $ThrottleMinutes)
    }
    if (-not $shouldLog) {
        return $false
    }
    $script:LastScpConnectFailLogUtc = $now
    Write-LoggerEvent -Level $Level -Message $Message
    return $true
}

function Invoke-ScpOutboundAllowReconcile {
    <#
      Best-effort Allow-ScpOutboundFirewall.ps1 so outbound SSH is not blocked
      by tighter LAN policies. Throttled to once per hour unless -Force.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [switch]$Force
    )

    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpHost)) {
        return $false
    }
    $now = [datetime]::UtcNow
    if (-not $Force -and ($script:LastScpAllowReconcileUtc -is [datetime])) {
        if (($now - $script:LastScpAllowReconcileUtc).TotalMinutes -lt 60) {
            return $false
        }
    }

    $port = 22
    if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
        $port = [int]$Config.ScpPort
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($script:ScpOnLockScriptDir)) {
        $parent = Split-Path -Parent $script:ScpOnLockScriptDir
        $candidates.Add((Join-Path $parent 'scripts\Allow-ScpOutboundFirewall.ps1'))
    }
    $candidates.Add((Join-Path $env:ProgramFiles 'LoginTimeLogger\scripts\Allow-ScpOutboundFirewall.ps1'))
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.UpdateClonePath)) {
        $candidates.Add((Join-Path ([string]$Config.UpdateClonePath) 'scripts\Allow-ScpOutboundFirewall.ps1'))
    }

    $scriptPath = $null
    foreach ($c in @($candidates)) {
        if (-not [string]::IsNullOrWhiteSpace($c) -and (Test-Path -LiteralPath $c)) {
            $scriptPath = $c
            break
        }
    }
    if ([string]::IsNullOrWhiteSpace($scriptPath)) {
        return $false
    }

    $script:LastScpAllowReconcileUtc = $now
    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    # Single ArgumentList string: string[] form drops -RemoteHost on WinPS 5.1.
    $quote = {
        param([string]$Value)
        if ($Value -match '[\s"]') {
            return ('"{0}"' -f ($Value -replace '"', '\"'))
        }
        return $Value
    }
    $argParts = @(
        '-NoProfile', '-NoLogo', '-ExecutionPolicy', 'Bypass',
        '-File', (& $quote $scriptPath),
        '-RemoteHost', ([string]$Config.ScpHost).Trim(),
        '-RemotePort', "$port"
    )
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.ConfigPath)) {
        $argParts += @('-ConfigPath', (& $quote ([string]$Config.ConfigPath)))
    }
    $argLine = $argParts -join ' '
    try {
        $p = Start-Process -FilePath $psExe -ArgumentList $argLine -Wait -PassThru -WindowStyle Hidden
        $code = if ($null -ne $p) { [int]$p.ExitCode } else { -1 }
        if ($code -eq 0) {
            Write-LoggerEvent ("SCP-Allow firewall reconcile OK ({0}:{1})" -f $Config.ScpHost, $port)
            return $true
        }
        Write-LoggerEvent -Level WARN -Message (
            "SCP-Allow firewall reconcile exit {0} ({1})" -f $code, $scriptPath)
        return $false
    }
    catch {
        Write-LoggerEvent -Level WARN -Message (
            "SCP-Allow firewall reconcile failed: {0}" -f $_.Exception.Message)
        return $false
    }
}

function Add-ScpCommonSshOptions {
    <#
      Appends shared OpenSSH client options for LoginTimeLogger scp calls.
      ConnectTimeout covers the initial TCP connect only; ServerAlive* detects
      a stalled session after connect so hung copies fail quickly.
    #>
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[string]]$ArgumentList,
        [Parameter(Mandatory)][string]$IdentityFile,
        [Parameter(Mandatory)][int]$Port,
        [string]$KnownHostsFile = '',
        [ValidateRange(5, 120)]
        [int]$ConnectTimeoutSeconds = 20,
        [switch]$VerboseSsh
    )

    $ArgumentList.Add('-i')
    $ArgumentList.Add($IdentityFile.Trim())
    $ArgumentList.Add('-P')
    $ArgumentList.Add("$Port")
    $ArgumentList.Add('-o')
    $ArgumentList.Add('BatchMode=yes')
    $ArgumentList.Add('-o')
    $ArgumentList.Add('IdentitiesOnly=yes')
    $ArgumentList.Add('-o')
    $ArgumentList.Add('PreferredAuthentications=publickey')
    $ArgumentList.Add('-o')
    $ArgumentList.Add('StrictHostKeyChecking=accept-new')
    if (-not [string]::IsNullOrWhiteSpace($KnownHostsFile)) {
        $ArgumentList.Add('-o')
        $ArgumentList.Add(('UserKnownHostsFile={0}' -f $KnownHostsFile.Trim()))
    }
    $ArgumentList.Add('-o')
    $ArgumentList.Add(('ConnectTimeout={0}' -f $ConnectTimeoutSeconds))
    # Detect dead peers after connect (ConnectTimeout does not cover transfer stalls).
    $ArgumentList.Add('-o')
    $ArgumentList.Add('ServerAliveInterval=10')
    $ArgumentList.Add('-o')
    $ArgumentList.Add('ServerAliveCountMax=3')
    if ($VerboseSsh) {
        $ArgumentList.Add('-v')
    }
}

function Stop-ScpProcessTree {
    param([Parameter(Mandatory)][System.Diagnostics.Process]$Process)

    if ($null -eq $Process) {
        return
    }
    try {
        if ($Process.HasExited) {
            return
        }
    }
    catch {
        return
    }

    $procId = 0
    try { $procId = [int]$Process.Id } catch { return }
    if ($procId -le 0) {
        return
    }

    # Prefer killing the whole tree (scp may spawn ssh.exe).
    $taskkill = Join-Path $env:SystemRoot 'System32\taskkill.exe'
    if (Test-Path -LiteralPath $taskkill) {
        $prevEap = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        try {
            $null = & $taskkill /PID $procId /T /F 2>&1
        }
        finally {
            $ErrorActionPreference = $prevEap
        }
    }
    else {
        try { Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue } catch { }
    }

    try { $null = $Process.WaitForExit(5000) } catch { }
}

function Invoke-ScpProcessWithTimeout {
    <#
      Starts scp via System.Diagnostics.Process (not Start-Process -PassThru,
      which often leaves ExitCode unset/-1 with empty redirect files on Windows).
      Waits up to TimeoutSeconds; on timeout kills the process tree.
      Captures stdout/stderr asynchronously and writes them to StdOutPath/StdErrPath.
    #>
    param(
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$ArgumentList,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 90
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $ScpExe
    $psi.Arguments = $ArgumentList
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    # OpenSSH for Windows can hang in banner/kex when stdin is not redirected
    # (interactive console scp works; redirected-only stdout/stderr stalls).
    $psi.RedirectStandardInput = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if (-not [string]::IsNullOrWhiteSpace($env:TEMP) -and (Test-Path -LiteralPath $env:TEMP)) {
        $psi.WorkingDirectory = $env:TEMP
    }

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    $stdoutTask = $null
    $stderrTask = $null
    $stdoutText = ''
    $stderrText = ''

    try {
        if (-not $proc.Start()) {
            return [pscustomobject]@{
                ExitCode = -1
                TimedOut = $false
                Process  = $null
            }
        }

        # No TTY prompts (BatchMode); close stdin so ssh/scp do not wait on input.
        try { $proc.StandardInput.Close() } catch { }

        # Read streams async before WaitForExit to avoid pipe-buffer deadlocks.
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()

        $timeoutMs = [Math]::Max(1000, $TimeoutSeconds * 1000)
        $exited = $false
        try {
            $exited = $proc.WaitForExit($timeoutMs)
        }
        catch {
            $exited = $false
        }

        if (-not $exited) {
            Stop-ScpProcessTree -Process $proc
            try {
                if ($null -ne $stdoutTask -and $stdoutTask.Wait(2000)) {
                    $stdoutText = [string]$stdoutTask.Result
                }
            }
            catch { }
            try {
                if ($null -ne $stderrTask -and $stderrTask.Wait(2000)) {
                    $stderrText = [string]$stderrTask.Result
                }
            }
            catch { }
            try {
                if (-not [string]::IsNullOrEmpty($StdOutPath)) {
                    Set-Content -LiteralPath $StdOutPath -Value $stdoutText -Encoding UTF8
                }
                if (-not [string]::IsNullOrEmpty($StdErrPath)) {
                    Set-Content -LiteralPath $StdErrPath -Value $stderrText -Encoding UTF8
                }
            }
            catch { }
            return [pscustomobject]@{
                ExitCode = -1
                TimedOut = $true
                Process  = $proc
            }
        }

        # Drain async readers, then ExitCode is reliable on Process (unlike Start-Process).
        try { $null = $proc.WaitForExit() } catch { }
        try {
            if ($null -ne $stdoutTask) { $stdoutText = [string]$stdoutTask.Result }
        }
        catch { }
        try {
            if ($null -ne $stderrTask) { $stderrText = [string]$stderrTask.Result }
        }
        catch { }

        $code = -1
        $gotCode = $false
        for ($i = 0; $i -lt 30 -and -not $gotCode; $i++) {
            try {
                $proc.Refresh()
                if ($proc.HasExited) {
                    $code = [int]$proc.ExitCode
                    $gotCode = $true
                }
            }
            catch {
                Start-Sleep -Milliseconds 20
            }
            if (-not $gotCode) {
                Start-Sleep -Milliseconds 20
            }
        }

        try {
            if (-not [string]::IsNullOrEmpty($StdOutPath)) {
                Set-Content -LiteralPath $StdOutPath -Value $stdoutText -Encoding UTF8
            }
            if (-not [string]::IsNullOrEmpty($StdErrPath)) {
                Set-Content -LiteralPath $StdErrPath -Value $stderrText -Encoding UTF8
            }
        }
        catch { }

        return [pscustomobject]@{
            ExitCode = $code
            TimedOut = $false
            Process  = $proc
        }
    }
    finally {
        try {
            if ($null -ne $proc -and -not $proc.HasExited) { }
        }
        catch { }
        try { $proc.Dispose() } catch { }
    }
}

function Test-ScpEndpointConfigured {
    <#
      True when host/user/remote-dir/identity are present (independent of feature flags).
    #>
    param([Parameter(Mandatory)]$Config)

    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpHost)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpUser)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpRemoteDirectory)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpIdentityFile)) {
        return $false
    }
    return $true
}

function Test-ScpOnLockConfigured {
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.ScpOnLockEnabled) {
        return $false
    }
    return (Test-ScpEndpointConfigured -Config $Config)
}

function Get-TargetUserProfilePath {
    <#
      Resolves the local profile folder for TargetUsername (works under SYSTEM).
    #>
    param([Parameter(Mandatory)][string]$TargetUsername)

    if (Get-Command Resolve-WindowsAccountSid -ErrorAction SilentlyContinue) {
        try {
            $sid = Resolve-WindowsAccountSid -UserName $TargetUsername
            if ($null -ne $sid -and (Get-Command Get-ProfilePathForSid -ErrorAction SilentlyContinue)) {
                $fromSid = Get-ProfilePathForSid -Sid $sid
                if (-not [string]::IsNullOrWhiteSpace($fromSid)) {
                    return $fromSid
                }
            }
        }
        catch { }
    }

    $sam = $TargetUsername
    if (Get-Command Get-AccountSamLeaf -ErrorAction SilentlyContinue) {
        try { $sam = Get-AccountSamLeaf -UserName $TargetUsername } catch { }
    }
    return (Join-Path $env:SystemDrive ('Users\{0}' -f $sam))
}

function Get-BHistoryInstallRootPaths {
    <#
      Candidate BH install directories (Program Files, Local\Programs, Uninstall registry).
    #>
    param(
        [Parameter(Mandatory)][string]$ProfilePath,
        [string[]]$InstallDirLeaves = @()
    )

    if ($null -eq $InstallDirLeaves -or $InstallDirLeaves.Count -eq 0) {
        $InstallDirLeaves = @($script:ScpBHistoryInstallDirLeaves)
    }

    $roots = New-Object System.Collections.Generic.List[string]
    $addRoot = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) { return }
        $trimmed = $Path.TrimEnd('\', '/')
        if ((Test-Path -LiteralPath $trimmed) -and -not $roots.Contains($trimmed)) {
            $roots.Add($trimmed)
        }
    }

    $programRoots = New-Object System.Collections.Generic.List[string]
    foreach ($pf in @([string]${env:ProgramFiles}, [string]${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($pf)) { $programRoots.Add($pf) }
    }
    $localPrograms = Join-Path $ProfilePath 'AppData\Local\Programs'
    if (-not [string]::IsNullOrWhiteSpace($localPrograms)) {
        $programRoots.Add($localPrograms)
    }

    foreach ($base in $programRoots) {
        foreach ($leaf in @($InstallDirLeaves)) {
            & $addRoot (Join-Path $base $leaf)
        }
    }

    $uninstallGlobs = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
    )
    foreach ($glob in $uninstallGlobs) {
        Get-ItemProperty -Path $glob -ErrorAction SilentlyContinue | ForEach-Object {
            # StrictMode: many Uninstall keys omit DisplayName / InstallLocation.
            $display = ''
            $install = ''
            $dnProp = $_.PSObject.Properties['DisplayName']
            $ilProp = $_.PSObject.Properties['InstallLocation']
            if ($null -ne $dnProp) { $display = [string]$dnProp.Value }
            if ($null -ne $ilProp) { $install = [string]$ilProp.Value }
            if ([string]::IsNullOrWhiteSpace($display) -or [string]::IsNullOrWhiteSpace($install)) {
                return
            }
            $matched = $false
            foreach ($leaf in @($InstallDirLeaves)) {
                $token = Split-Path -Leaf ([string]$leaf)
                if ([string]::IsNullOrWhiteSpace($token)) { continue }
                if ($display.IndexOf($token, [System.StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                return
            }
            & $addRoot $install
        }
    }

    # Do not wrap with unary comma: callers use @() and a wrapped array
    # becomes one nested element (breaks multi-hit and empty results).
    return $roots.ToArray()
}

function Resolve-BHistoryPathForFamily {
    <#
      First existing BH path for one b family.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetUsername,
        [string]$PreferredAbsolute = '',
        [string[]]$RoamingRels = @(),
        [string[]]$LocalRels = @(),
        [string[]]$InstallDirLeaves = @()
    )

    $tried = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    $tryPath = {
        param([string]$Candidate)
        if ([string]::IsNullOrWhiteSpace($Candidate)) { return $null }
        if (-not $tried.Add($Candidate)) { return $null }
        if (Test-Path -LiteralPath $Candidate) { return $Candidate }
        return $null
    }

    if (-not [string]::IsNullOrWhiteSpace($PreferredAbsolute)) {
        $hit = & $tryPath $PreferredAbsolute
        if (-not [string]::IsNullOrWhiteSpace($hit)) { return $hit }
    }

    $profile = Get-TargetUserProfilePath -TargetUsername $TargetUsername
    $roaming = Join-Path $profile 'AppData\Roaming'
    $local = Join-Path $profile 'AppData\Local'

    foreach ($rel in @($RoamingRels)) {
        $hit = & $tryPath (Join-Path $roaming ([string]$rel))
        if (-not [string]::IsNullOrWhiteSpace($hit)) { return $hit }
    }
    foreach ($rel in @($LocalRels)) {
        $hit = & $tryPath (Join-Path $local ([string]$rel))
        if (-not [string]::IsNullOrWhiteSpace($hit)) { return $hit }
    }

    if ($null -ne $InstallDirLeaves -and $InstallDirLeaves.Count -gt 0) {
        $installRoots = @(Get-BHistoryInstallRootPaths -ProfilePath $profile -InstallDirLeaves $InstallDirLeaves)
        foreach ($installRoot in $installRoots) {
            foreach ($rel in @($script:ScpBHistoryInstallRels)) {
                $hit = & $tryPath (Join-Path $installRoot $rel)
                if (-not [string]::IsNullOrWhiteSpace($hit)) { return $hit }
            }
        }
    }

    return ''
}

function Get-BHistoryStageLeafSafeName {
    <#
      Sanitize a profile directory name for use in StageLeaf.
      Spaces become '-' (Profile 1 -> Profile-1).
    #>
    param([Parameter(Mandatory)][string]$Name)

    $s = $Name.Trim()
    if ([string]::IsNullOrWhiteSpace($s)) {
        return 'unknown'
    }
    foreach ($ch in [System.IO.Path]::GetInvalidFileNameChars()) {
        $s = $s.Replace([string]$ch, '_')
    }
    # Replace remaining whitespace with '-' (e.g. Profile 1 -> Profile-1).
    $s = [regex]::Replace($s, '\s+', '-')
    return $s
}

function New-BHistoryRootAccumulator {
    <#
      Unique existing directory collector (Roots + Seen). Use Add-BHistoryRootPath.
    #>
    return [pscustomobject]@{
        Roots = New-Object System.Collections.Generic.List[string]
        Seen  = New-Object 'System.Collections.Generic.HashSet[string]' `
            ([StringComparer]::OrdinalIgnoreCase)
    }
}

function Add-BHistoryRootPath {
    <#
      Add an existing directory to a New-BHistoryRootAccumulator (deduped).
    #>
    param(
        [Parameter(Mandatory)]$Accumulator,
        [string]$Path
    )

    if ([string]::IsNullOrWhiteSpace($Path)) { return }
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($Path)
    }
    catch {
        $full = $Path
    }
    if ($Accumulator.Seen.Add($full)) {
        $Accumulator.Roots.Add($full)
    }
}

function Add-BHistoryProductRootFromPreferredHistory {
    <#
      If PreferredAbsolute ends with ...\<profile>\History, add the product root
      (parent of the profile directory).
    #>
    param(
        [string]$PreferredAbsolute,
        [Parameter(Mandatory)]$Accumulator
    )

    if ([string]::IsNullOrWhiteSpace($PreferredAbsolute)) { return }
    if (-not ([string](Split-Path -Leaf $PreferredAbsolute)).Equals(
            'History', [StringComparison]::OrdinalIgnoreCase)) {
        return
    }
    $profileDir = Split-Path -Parent $PreferredAbsolute
    if ([string]::IsNullOrWhiteSpace($profileDir)) { return }
    Add-BHistoryRootPath -Accumulator $Accumulator -Path (Split-Path -Parent $profileDir)
}

function Add-BHistoryProfileSource {
    <#
      Append one History DB to $Sources when the file exists (dedupe path/leaf).
    #>
    param(
        # AllowEmptyCollection: a new List[object] is empty on first add.
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [System.Collections.Generic.List[object]]$Sources,

        [Parameter(Mandatory)]$SeenHist,
        [Parameter(Mandatory)]$UsedLeaves,
        [Parameter(Mandatory)][string]$StagePrefix,
        [string]$HistPath,
        [Parameter(Mandatory)][string]$ProfileName
    )

    if ([string]::IsNullOrWhiteSpace($HistPath)) { return }
    if (-not (Test-Path -LiteralPath $HistPath -PathType Leaf)) { return }
    try {
        $full = [System.IO.Path]::GetFullPath($HistPath)
    }
    catch {
        $full = $HistPath
    }
    if (-not $SeenHist.Add($full)) { return }

    $safe = Get-BHistoryStageLeafSafeName -Name $ProfileName
    $leaf = '{0}-{1}' -f $StagePrefix, $safe
    if (-not $UsedLeaves.Add($leaf)) {
        $n = 2
        while (-not $UsedLeaves.Add(('{0}-{1}' -f $leaf, $n))) {
            $n++
        }
        $leaf = '{0}-{1}' -f $leaf, $n
    }
    $Sources.Add([pscustomobject]@{
            Path      = $full
            StageLeaf = $leaf
        })
}

function Get-ProfileHistorySourcesFromRoots {
    <#
      Scan product/User Data roots for profile History DBs.
      StageLeaf = <StagePrefix>-<safe_profile_name>.
      When IncludeRootHistory is set, also pick History sitting directly under the root
      (legacy product-root History) as <StagePrefix>-Default if that leaf is free.
    #>
    param(
        [string[]]$Roots = @(),
        [Parameter(Mandatory)][string]$StagePrefix,
        [bool]$IncludeRootHistory = $false
    )

    $sources = New-Object System.Collections.Generic.List[object]
    $seenHist = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)
    $usedLeaves = New-Object 'System.Collections.Generic.HashSet[string]' `
        ([StringComparer]::OrdinalIgnoreCase)

    foreach ($root in @($Roots)) {
        if ([string]::IsNullOrWhiteSpace([string]$root)) { continue }
        if (-not (Test-Path -LiteralPath $root -PathType Container)) { continue }

        if ($IncludeRootHistory) {
            Add-BHistoryProfileSource -Sources $sources -SeenHist $seenHist `
                -UsedLeaves $usedLeaves -StagePrefix $StagePrefix `
                -HistPath (Join-Path $root 'History') -ProfileName 'Default'
        }

        $profileDirs = @(Get-ChildItem -LiteralPath $root -Directory -Force `
                -ErrorAction SilentlyContinue)
        foreach ($dir in $profileDirs) {
            Add-BHistoryProfileSource -Sources $sources -SeenHist $seenHist `
                -UsedLeaves $usedLeaves -StagePrefix $StagePrefix `
                -HistPath (Join-Path $dir.FullName 'History') `
                -ProfileName ([string]$dir.Name)
        }
    }

    return $sources.ToArray()
}

function Get-ChBHistoryUserDataRoots {
    <#
      Candidate secondary (ch) User Data directories for the target user
      (Local AppData, preferred absolute parent, install-dir User Data).
    #>
    param([string]$TargetUsername = '')

    $acc = New-BHistoryRootAccumulator
    Add-BHistoryProductRootFromPreferredHistory `
        -PreferredAbsolute ([string]$script:ScpBHistoryPreferredAbsoluteSecondary) `
        -Accumulator $acc

    if (-not [string]::IsNullOrWhiteSpace($TargetUsername)) {
        $profile = Get-TargetUserProfilePath -TargetUsername $TargetUsername
        $local = Join-Path $profile 'AppData\Local'
        if (-not [string]::IsNullOrWhiteSpace([string]$script:ScpBHistoryChUserDataRel)) {
            Add-BHistoryRootPath -Accumulator $acc `
                -Path (Join-Path $local ([string]$script:ScpBHistoryChUserDataRel))
        }

        $installRoots = @(Get-BHistoryInstallRootPaths `
                -ProfilePath $profile `
                -InstallDirLeaves @($script:ScpBHistorySecondaryInstallDirLeaves))
        foreach ($installRoot in $installRoots) {
            Add-BHistoryRootPath -Accumulator $acc -Path (Join-Path $installRoot 'User Data')
        }
    }

    return $acc.Roots.ToArray()
}

function Get-ChBHistorySources {
    <#
      Every secondary (ch) profile History DB under discovered User Data roots.
      StageLeaf = log-history-ch-<profile_dir_name> (e.g. log-history-ch-Default,
      log-history-ch-Profile-1).
    #>
    param([string]$TargetUsername = '')

    return @(Get-ProfileHistorySourcesFromRoots `
            -Roots @(Get-ChBHistoryUserDataRoots -TargetUsername $TargetUsername) `
            -StagePrefix 'log-history-ch' `
            -IncludeRootHistory:$false)
}

function Get-OpBHistoryUserDataRoots {
    <#
      Candidate primary (op) product directories (Roaming/Local + preferred + install).
      Profiles (Default, Profile 1, …) live under these roots.
    #>
    param([string]$TargetUsername = '')

    $acc = New-BHistoryRootAccumulator
    Add-BHistoryProductRootFromPreferredHistory `
        -PreferredAbsolute ([string]$script:ScpBHistoryPreferredAbsolute) `
        -Accumulator $acc

    if (-not [string]::IsNullOrWhiteSpace($TargetUsername)) {
        $profile = Get-TargetUserProfilePath -TargetUsername $TargetUsername
        $roaming = Join-Path $profile 'AppData\Roaming'
        $local = Join-Path $profile 'AppData\Local'
        foreach ($rel in @($script:ScpBHistoryOpProductRels)) {
            if ([string]::IsNullOrWhiteSpace([string]$rel)) { continue }
            Add-BHistoryRootPath -Accumulator $acc -Path (Join-Path $roaming ([string]$rel))
            Add-BHistoryRootPath -Accumulator $acc -Path (Join-Path $local ([string]$rel))
        }

        $installRoots = @(Get-BHistoryInstallRootPaths `
                -ProfilePath $profile `
                -InstallDirLeaves @($script:ScpBHistoryInstallDirLeaves))
        foreach ($installRoot in $installRoots) {
            # Install tree may hold profile\History or Default\History.
            Add-BHistoryRootPath -Accumulator $acc -Path $installRoot
            Add-BHistoryRootPath -Accumulator $acc -Path (Join-Path $installRoot 'profile')
        }
    }

    return $acc.Roots.ToArray()
}

function Get-OpBHistorySources {
    <#
      Every primary (op) profile History DB under discovered product roots.
      StageLeaf = log-history-op-<profile_dir_name> (e.g. log-history-op-Default,
      log-history-op-Profile-1). Legacy History directly under the product root
      is included as log-history-op-Default when present.
    #>
    param([string]$TargetUsername = '')

    return @(Get-ProfileHistorySourcesFromRoots `
            -Roots @(Get-OpBHistoryUserDataRoots -TargetUsername $TargetUsername) `
            -StagePrefix 'log-history-op' `
            -IncludeRootHistory:$true)
}

function Get-BHistorySources {
    <#
      All discoverable History DBs for the target user:
        - every primary (op) profile History as log-history-op-<profile_name>
        - every secondary (ch) profile History as log-history-ch-<profile_name>
      Returns objects: Path, StageLeaf (remote/temp file name).
    #>
    param(
        [Parameter(Mandatory)][string]$TargetUsername
    )

    $sources = New-Object System.Collections.Generic.List[object]

    foreach ($op in @(Get-OpBHistorySources -TargetUsername $TargetUsername)) {
        $sources.Add($op)
    }
    foreach ($ch in @(Get-ChBHistorySources -TargetUsername $TargetUsername)) {
        $sources.Add($ch)
    }

    # Do not wrap with unary comma: callers use @() and a wrapped array
    # becomes one nested element (Path member enumeration joins with spaces).
    return $sources.ToArray()
}

function Get-BHistoryPath {
    <#
      First existing BHistory path for the target user (primary family).
      Prefer Get-BHistorySources when all families are needed.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetUsername
    )

    $sources = @(Get-BHistorySources -TargetUsername $TargetUsername)
    if ($sources.Count -gt 0) {
        return [string]$sources[0].Path
    }
    return ''
}

function Copy-FileWithSharedRead {
    <#
      Copies a file that may be locked by another process (e.g. SQLite History)
      using FileShare.ReadWrite. Returns $true on success.
    #>
    param(
        [Parameter(Mandatory)][string]$SourcePath,
        [Parameter(Mandatory)][string]$DestinationPath
    )

    $inStream = $null
    $outStream = $null
    try {
        $destDir = Split-Path -Parent $DestinationPath
        if (-not [string]::IsNullOrWhiteSpace($destDir) -and -not (Test-Path -LiteralPath $destDir)) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        }
        $inStream = [System.IO.File]::Open(
            $SourcePath,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            [System.IO.FileShare]::ReadWrite)
        $outStream = [System.IO.File]::Create($DestinationPath)
        $inStream.CopyTo($outStream)
        return $true
    }
    catch {
        return $false
    }
    finally {
        if ($null -ne $outStream) { $outStream.Dispose() }
        if ($null -ne $inStream) { $inStream.Dispose() }
    }
}

function New-ScpBHistoryUploadFiles {
    <#
      Stages shared-read copies of each discovered History DB under TEMP
      (log-history-op-<profile>, log-history-ch-<profile>, ...). Returns staged
      full paths. Caller must delete returned paths when finished.
      When TargetUsername is empty, stages every op/ch profile under
      preferred/discovered product roots.
    #>
    param([string]$TargetUsername = '')

    $staged = New-Object System.Collections.Generic.List[string]
    $sources = New-Object System.Collections.Generic.List[object]

    if (-not [string]::IsNullOrWhiteSpace($TargetUsername)) {
        foreach ($src in @(Get-BHistorySources -TargetUsername $TargetUsername)) {
            $sources.Add($src)
        }
    }
    else {
        foreach ($op in @(Get-OpBHistorySources -TargetUsername '')) {
            $sources.Add($op)
        }
        foreach ($ch in @(Get-ChBHistorySources -TargetUsername '')) {
            $sources.Add($ch)
        }
    }

    # Do not wrap List[object] with @(): PowerShell throws "Argument types do
    # not match" when the list holds PSCustomObject rows (breaks all staging).
    $stageDir = Join-Path $env:TEMP ('LoginTimeLogger-bhist-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Path $stageDir -Force | Out-Null
    }
    catch {
        $stageDir = $env:TEMP
    }
    foreach ($src in $sources) {
        $sourcePath = [string]$src.Path
        $leaf = [string]$src.StageLeaf
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($leaf)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }
        $stagedPath = Join-Path $stageDir $leaf
        if (Test-Path -LiteralPath $stagedPath) {
            Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        }
        if (Copy-FileWithSharedRead -SourcePath $sourcePath -DestinationPath $stagedPath) {
            $staged.Add($stagedPath)
        }
        else {
            Write-BHistoryCsvEvent -Level WARN -Message (
                'BHistory stage failed (shared-read copy): {0} -> {1}' -f $sourcePath, $stagedPath)
        }
    }
    # Callers must wrap with @() WITHOUT piping first (a single string return is
    # character-enumerated by Where-Object/ForEach-Object in Windows PowerShell).
    return [string[]]$staged.ToArray()
}

function New-ScpBHistoryUploadFile {
    <#
      Stages shared-read History copies; returns the first staged path
      (or '' when none). Prefer New-ScpBHistoryUploadFiles for all families.
    #>
    param([Parameter(Mandatory)][string]$TargetUsername)

    $all = @(New-ScpBHistoryUploadFiles -TargetUsername $TargetUsername)
    if ($all.Count -gt 0) {
        return [string]$all[0]
    }
    return ''
}

function Write-BHistoryCsvEvent {
    param(
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO',
        [Parameter(Mandatory)][string]$Message
    )
    if (Get-Command Write-LoggerEvent -ErrorAction SilentlyContinue) {
        Write-LoggerEvent -Level $Level -Message $Message
        return
    }
    Write-Host ("[BHistory CSV][{0}] {1}" -f $Level, $Message)
}

function Resolve-ConvertLogBhToCsvScript {
    <#
      Locate Convert-LogBhToCsv.ps1 under install/repo scripts/.
    #>
    $roots = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ScpOnLockScriptDir)) {
        $roots.Add((Split-Path -Parent ([string]$script:ScpOnLockScriptDir)))
    }
    $pf = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    if (-not [string]::IsNullOrWhiteSpace($pf)) {
        $roots.Add($pf)
    }
    foreach ($root in $roots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        $candidate = Join-Path $root 'scripts\Convert-LogBhToCsv.ps1'
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Get-BHistoryCsvDirectory {
    <#
      LogDirectory\bhist for dated History CSV exports.
    #>
    param([Parameter(Mandatory)]$Config)

    $logDir = [string]$Config.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        throw 'LogDirectory missing; cannot create bhist CSV directory.'
    }
    $dir = Join-Path $logDir 'bhist'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Test-BHistoryStagedLeafName {
    <#
      True for log-history-op / log-history-op-<profile> / log-history-ch-<profile>.
    #>
    param([string]$Leaf)

    if ([string]::IsNullOrWhiteSpace($Leaf)) { return $false }
    return ($Leaf -eq 'log-history-op') -or
        ($Leaf -like 'log-history-op-*') -or
        ($Leaf -like 'log-history-ch-*')
}

function New-BHistoryCsvExports {
    <#
      For every discovered op/ch profile History DB:
        1) stage a shared-read copy
        2) run Convert-LogBhToCsv.ps1 -PreviousDays 1
        3) write LogDirectory\bhist\
             log-history-op-<profile>-YYYY-MM-DD.csv
             log-history-ch-<profile>-YYYY-MM-DD.csv
      Returns all of today's dated CSVs under bhist (for SCP upload).
      0-row converts omit/remove that profile's CSV by design.
      Temp staged SQLite copies are deleted before return.
    #>
    param([Parameter(Mandatory)]$Config)

    $csvPaths = New-Object System.Collections.Generic.List[string]
    $convertFailures = New-Object System.Collections.Generic.List[string]
    $convertScript = Resolve-ConvertLogBhToCsvScript
    if ([string]::IsNullOrWhiteSpace($convertScript)) {
        Write-BHistoryCsvEvent -Level WARN -Message (
            'BHistory CSV: Convert-LogBhToCsv.ps1 not found under install/repo scripts.')
        $null = Send-LoginTimeLoggerFailureAlert `
            -Subject 'BHistory CSV convert failed' `
            -Body 'Convert-LogBhToCsv.ps1 not found under install/repo scripts.' `
            -AlertKey 'bhist-csv-convert-failed' `
            -Config $Config
        return [string[]]@()
    }

    $bhistDir = Get-BHistoryCsvDirectory -Config $Config
    $day = Get-Date -Format 'yyyy-MM-dd'
    $staged = @()
    try {
        $staged = @(New-ScpBHistoryUploadFiles -TargetUsername ([string]$Config.TargetUsername))
        $opStaged = @($staged | Where-Object {
                $leaf = Split-Path -Leaf ([string]$_)
                ($leaf -eq 'log-history-op') -or ($leaf -like 'log-history-op-*')
            })
        $chStaged = @($staged | Where-Object {
                (Split-Path -Leaf ([string]$_)) -like 'log-history-ch-*'
            })
        Write-BHistoryCsvEvent -Message (
            'BHistory CSV: staged {0} DB(s) (op={1}, ch={2}) for -PreviousDays 1.' -f `
                $staged.Count, $opStaged.Count, $chStaged.Count)
        if ($staged.Count -eq 0) {
            Write-BHistoryCsvEvent -Level WARN -Message (
                'BHistory CSV: no History DB could be staged for conversion.')
            $convertFailures.Add('no History DB could be staged for conversion')
        }

        foreach ($dbPath in $staged) {
            if ([string]::IsNullOrWhiteSpace([string]$dbPath)) { continue }
            $leaf = Split-Path -Leaf ([string]$dbPath)
            if (-not (Test-BHistoryStagedLeafName -Leaf $leaf)) {
                continue
            }
            # log-history-op-<profile>-YYYY-MM-DD.csv / log-history-ch-<profile>-YYYY-MM-DD.csv
            $outPath = Join-Path $bhistDir ('{0}-{1}.csv' -f $leaf, $day)
            $convertExit = -1
            try {
                Write-BHistoryCsvEvent -Message (
                    "BHistory CSV: Convert-LogBhToCsv.ps1 -PreviousDays 1 ({0} -> {1})" -f `
                        $leaf, $outPath)
                # Capture success-stream noise from Convert/Python so it does not
                # pollute this function's return value.
                # Avoid stale LASTEXITCODE from prior native commands in this runspace
                # ([int]$null is 0, but a leftover 1 falsely marks Convert as failed).
                $global:LASTEXITCODE = 0
                $convertParams = @{
                    InputPath    = [string]$dbPath
                    OutputPath   = $outPath
                    PreviousDays = 1
                }
                $runtimeConfigPath = ''
                if ($Config -and $Config.PSObject.Properties['ConfigPath'] -and
                    -not [string]::IsNullOrWhiteSpace([string]$Config.ConfigPath)) {
                    $runtimeConfigPath = [string]$Config.ConfigPath
                    $convertParams['ConfigPath'] = $runtimeConfigPath
                }
                $convertOut = @(& $convertScript @convertParams 2>&1)
                if ($null -eq $LASTEXITCODE) {
                    $convertExit = 0
                }
                else {
                    $convertExit = [int]$LASTEXITCODE
                }
                $convertDetail = New-Object System.Collections.Generic.List[string]
                foreach ($line in $convertOut) {
                    $text = [string]$line
                    if ([string]::IsNullOrWhiteSpace($text)) { continue }
                    Write-BHistoryCsvEvent -Message $text
                    if ($convertDetail.Count -lt 12) {
                        $convertDetail.Add($text.Trim())
                    }
                }
                if ($convertExit -ne 0) {
                    $detailSuffix = ''
                    if ($convertDetail.Count -gt 0) {
                        $detailSuffix = (' Detail: {0}' -f ($convertDetail -join ' | '))
                    }
                    $failLine = ('BHistory CSV convert failed for {0} (exit {1}).{2}' -f `
                            $leaf, $convertExit, $detailSuffix)
                    Write-BHistoryCsvEvent -Level WARN -Message $failLine
                    $convertFailures.Add($failLine)
                }
            }
            catch {
                $failLine = ('BHistory CSV convert error for {0}: {1}' -f `
                        $leaf, $_.Exception.Message)
                Write-BHistoryCsvEvent -Level WARN -Message $failLine
                $convertFailures.Add($failLine)
            }
            if (Test-Path -LiteralPath $outPath) {
                $csvPaths.Add((Get-Item -LiteralPath $outPath -Force).FullName)
            }
            elseif ($convertExit -ne 0) {
                $failLine = ('BHistory CSV: no output file after failed convert: {0}' -f $outPath)
                Write-BHistoryCsvEvent -Level WARN -Message $failLine
                $convertFailures.Add($failLine)
            }
            else {
                # 0 visit rows for -PreviousDays 1: Convert exits 0 and omits the CSV by design.
                Write-BHistoryCsvEvent -Message (
                    'BHistory CSV: no rows for -PreviousDays 1 (CSV not written): {0}' -f $outPath)
            }
        }

        # Always upload every current-date CSV under bhist (all op/ch profiles).
        $seenCsv = @{}
        foreach ($existing in @($csvPaths)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$existing)) {
                $seenCsv[[string]$existing.ToLowerInvariant()] = $true
            }
        }
        if (Test-Path -LiteralPath $bhistDir) {
            Get-ChildItem -LiteralPath $bhistDir -File -Force `
                -Filter ('log-history-*-{0}.csv' -f $day) -ErrorAction SilentlyContinue |
                Sort-Object Name |
                ForEach-Object {
                    $full = $_.FullName
                    $key = $full.ToLowerInvariant()
                    if (-not $seenCsv.ContainsKey($key)) {
                        $seenCsv[$key] = $true
                        $csvPaths.Add($full)
                    }
                }
        }
        Write-BHistoryCsvEvent -Message (
            'BHistory CSV: {0} file(s) ready for SCP upload for {1}: {2}' -f `
                $csvPaths.Count, $day, (
                ($csvPaths | ForEach-Object { Split-Path -Leaf $_ }) -join ', '))

        if ($convertFailures.Count -gt 0) {
            $body = @(
                ('BHistory CSV convert failures ({0}):' -f $convertFailures.Count)
                ''
            ) + @($convertFailures)
            $null = Send-LoginTimeLoggerFailureAlert `
                -Subject 'BHistory CSV convert failed' `
                -Body ($body -join [Environment]::NewLine) `
                -AlertKey 'bhist-csv-convert-failed' `
                -Config $Config
        }
    }
    finally {
        foreach ($tempCopy in @($staged)) {
            if (-not [string]::IsNullOrWhiteSpace([string]$tempCopy) -and
                (Test-Path -LiteralPath ([string]$tempCopy))) {
                Remove-Item -LiteralPath ([string]$tempCopy) -Force -ErrorAction SilentlyContinue
            }
        }
    }

    return [string[]]$csvPaths.ToArray()
}

function Get-ScpOnLockMissingConfigFields {
    param([Parameter(Mandatory)]$Config)

    $missing = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpHost)) { $missing.Add('ScpHost') }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpUser)) { $missing.Add('ScpUser') }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpRemoteDirectory)) { $missing.Add('ScpRemoteDirectory') }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpIdentityFile)) { $missing.Add('ScpIdentityFile') }
    return @($missing)
}

function Get-ScpOnLockSourceFiles {
    <#
      Collects log files for SCP-on-lock: the two newest unlocked-time-*.log
      files under LogDirectory, all error logs, service.log, and today's
      BH under LogDirectory\bhist (after convert).
      Does not copy summary CSV, state.json, or older time logs.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$TimeLogPath = '',
        [string]$ErrorLogPath = ''
    )

    $files = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $addFile = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            $full = $Path
        }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            return
        }
        $seen[$key] = $true
        $files.Add($full)
    }

    $logDir = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $logDir = [string]$Config.LogDirectory
    }

    # Two newest unlocked-time-*.log (by LastWriteTime, then name).
    $timeLogs = @()
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and (Test-Path -LiteralPath $logDir)) {
        $timeLogs = @(
            Get-ChildItem -LiteralPath $logDir -File -Force `
                -Filter 'unlocked-time-*.log' -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime, Name -Descending |
                Select-Object -First 2
        )
    }
    foreach ($tl in $timeLogs) {
        & $addFile $tl.FullName
    }
    # If LogDirectory had no matches yet but caller passed today's path, include it.
    if ($timeLogs.Count -eq 0) {
        & $addFile $TimeLogPath
    }

    # All error logs: explicit path, current Get-ErrorLogPath, and errors.log under LogDirectory.
    & $addFile $ErrorLogPath
    if (Get-Command Get-ErrorLogPath -ErrorAction SilentlyContinue) {
        try { & $addFile (Get-ErrorLogPath) } catch { }
    }
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and (Test-Path -LiteralPath $logDir)) {
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'errors.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter '*error*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }

        & $addFile (Join-Path $logDir 'service.log')
    }

    # Today's history CSVs: convert then include every log-history-*-YYYY-MM-DD.csv.
    try {
        foreach ($csv in @(New-BHistoryCsvExports -Config $Config)) {
            & $addFile ([string]$csv)
        }
    }
    catch {
        $day = Get-Date -Format 'yyyy-MM-dd'
        if (-not [string]::IsNullOrWhiteSpace($logDir)) {
            $bhistDir = Join-Path $logDir 'bhist'
            if (Test-Path -LiteralPath $bhistDir) {
                Get-ChildItem -LiteralPath $bhistDir -File -Force `
                    -Filter ('log-history-*-{0}.csv' -f $day) -ErrorAction SilentlyContinue |
                    ForEach-Object { & $addFile $_.FullName }
            }
        }
    }

    return @($files)
}

function Get-ScpManualSourceFiles {
    <#
      Collects a fuller set for manual SCP: every unlocked-time-*.log under
      LogDirectory, all error logs, debug.log, state.json, every *.csv under
      LogDirectory (recursive, including bhist history CSVs and
      unlocked-time-summary.csv), and any raw History DB copies already under
      LogDirectory (log-history-* without a .csv extension). Refreshes today's
      history CSVs via New-BHistoryCsvExports when available. Does not include
      service.log or stage live BH (callers use New-ScpBHistoryUploadFiles).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [string]$ErrorLogPath = ''
    )

    $files = New-Object System.Collections.Generic.List[string]
    $seen = @{}

    $addFile = {
        param([string]$Path)
        if ([string]::IsNullOrWhiteSpace($Path)) {
            return
        }
        if (-not (Test-Path -LiteralPath $Path)) {
            return
        }
        try {
            $full = [System.IO.Path]::GetFullPath($Path)
        }
        catch {
            $full = $Path
        }
        $key = $full.ToLowerInvariant()
        if ($seen.ContainsKey($key)) {
            return
        }
        $seen[$key] = $true
        $files.Add($full)
    }

    $logDir = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $logDir = [string]$Config.LogDirectory
    }

    # Refresh today's history CSVs before collecting all *.csv under LogDirectory.
    try {
        $null = @(New-BHistoryCsvExports -Config $Config)
    }
    catch { }

    if (-not [string]::IsNullOrWhiteSpace($logDir) -and (Test-Path -LiteralPath $logDir)) {
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'unlocked-time-*.log' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { & $addFile $_.FullName }

        & $addFile (Join-Path $logDir 'state.json')
        & $addFile (Join-Path $logDir 'debug.log')

        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'errors.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter '*error*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }

        # All CSV files under LogDirectory (summary, bhist history CSVs, …).
        Get-ChildItem -LiteralPath $logDir -File -Force -Recurse `
            -Filter '*.csv' -ErrorAction SilentlyContinue |
            Sort-Object FullName |
            ForEach-Object { & $addFile $_.FullName }

        # Raw History DB snapshots (log-history-op / log-history-ch / …), not CSVs.
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'log-history-*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -ne '.csv' } |
            Sort-Object Name |
            ForEach-Object { & $addFile $_.FullName }
    }

    & $addFile $ErrorLogPath
    if (Get-Command Get-ErrorLogPath -ErrorAction SilentlyContinue) {
        try { & $addFile (Get-ErrorLogPath) } catch { }
    }

    return @($files)
}

function Send-LoginTimeLoggerFailureAlert {
    <#
      Emails a monitor failure with errors.log / service.log attached (when SMTP
      is enabled). Used for SCP-on-lock, SCP BHistory/daily, and BHistory CSV
      convert failures.
    #>
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)][string]$AlertKey,
        [Parameter(Mandatory)]$Config,
        [string]$ErrorLogPath = '',
        [string[]]$ExtraAttachment = @()
    )

    if (-not (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue)) {
        return $false
    }

    $attachments = New-Object System.Collections.Generic.List[string]
    $add = {
        param([string]$Path)
        if (-not [string]::IsNullOrWhiteSpace($Path) -and (Test-Path -LiteralPath $Path)) {
            $attachments.Add($Path)
        }
    }

    & $add $ErrorLogPath
    if (Get-Command Get-ErrorLogPath -ErrorAction SilentlyContinue) {
        try { & $add (Get-ErrorLogPath) } catch { }
    }
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        & $add (Join-Path ([string]$Config.LogDirectory) 'service.log')
    }
    foreach ($extra in @($ExtraAttachment)) {
        & $add $extra
    }

    return (Send-LoginTimeSmtpAlert `
            -Subject $Subject `
            -Body $Body `
            -AlertKey $AlertKey `
            -Attachment @($attachments))
}

function Send-ScpOnLockFailureAlert {
    <#
      Emails an SCP-on-lock failure with local error/service logs attached (when SMTP enabled).
    #>
    param(
        [Parameter(Mandatory)][string]$Body,
        [Parameter(Mandatory)]$Config,
        [string]$ErrorLogPath = '',
        [string[]]$ExtraAttachment = @()
    )

    return (Send-LoginTimeLoggerFailureAlert `
            -Subject 'SCP on lock failed' `
            -Body $Body `
            -AlertKey 'scp-on-lock-failed' `
            -Config $Config `
            -ErrorLogPath $ErrorLogPath `
            -ExtraAttachment $ExtraAttachment)
}

function Invoke-ScpLogCopyOnLock {
    <#
    .SYNOPSIS
      Copies LoginTimeLogger logs to the configured remote via scp on screen lock.
      Copies the two newest unlocked-time-*.log files, all error logs,
      service.log, and today's BH CSVs under LogDirectory\bhist.
      Failures are logged; they do not stop the monitor. Failed copies also
      email with error logs attached when SMTP is enabled.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TimeLogPath,
        [Parameter(Mandatory)][string]$ErrorLogPath
    )

    if (-not $Config.ScpOnLockEnabled) {
        return
    }
    if (-not (Test-ScpOnLockConfigured -Config $Config)) {
        $missing = Get-ScpOnLockMissingConfigFields -Config $Config
        Write-LoggerEvent -Level ERROR -Message (
            ("SCP on lock skipped: ScpOnLockEnabled=true but config incomplete (missing: {0})." -f `
                (($missing -join ', '))))
        return
    }

    try {
        $scpExe = Find-ScpExecutable
        if (-not $scpExe) {
            Write-LoggerEvent -Level ERROR -Message 'SCP on lock skipped: scp.exe not found (install OpenSSH Client).'
            return
        }

        if (-not (Test-Path -LiteralPath $Config.ScpIdentityFile)) {
            Write-LoggerEvent -Level ERROR -Message ("SCP on lock skipped: identity file missing: {0}" -f $Config.ScpIdentityFile)
            return
        }

        # SYSTEM-run OpenSSH rejects keys with admin/user ACEs ("too open").
        try {
            Protect-ScpPrivateKeyFile -IdentityPath ([string]$Config.ScpIdentityFile)
        }
        catch {
            Write-LoggerEvent -Level WARN -Message (
                "SCP identity ACL harden failed: {0}" -f $_.Exception.Message)
        }

        $files = @(Get-ScpOnLockSourceFiles -Config $Config -TimeLogPath $TimeLogPath -ErrorLogPath $ErrorLogPath)
        if ($files.Count -eq 0) {
            Write-LoggerEvent -Level WARN -Message (
                ("SCP on lock skipped: no log files found (TimeLog='{0}'; ErrorLog='{1}'; LogDirectory='{2}')." -f `
                    $TimeLogPath, $ErrorLogPath, $Config.LogDirectory))
            return
        }

        $remoteDir = ([string]$Config.ScpRemoteDirectory).Trim()
        if (-not $remoteDir.EndsWith('/')) {
            $remoteDir = $remoteDir + '/'
        }
        $scpHost = ([string]$Config.ScpHost).Trim()
        $scpUser = ([string]$Config.ScpUser).Trim()
        $remoteTarget = '{0}@{1}:{2}' -f $scpUser, $scpHost, $remoteDir

        $port = 22
        if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
            $port = [int]$Config.ScpPort
        }

        # OpenSSH handshake preflight (not .NET TcpClient); honor connect backoff.
        if (Test-ScpConnectBackoffActive) {
            $remain = [int][Math]::Ceiling(
                ($script:ScpConnectBackoffUntilUtc - [datetime]::UtcNow).TotalMinutes)
            Write-LoggerEvent -Level WARN -Message (
                "SCP on lock skipped: connect backoff active (~{0} min left)." -f $remain)
            return
        }
        $hostReachable = Test-ScpRemoteReady `
            -HostName $scpHost `
            -Port $port `
            -UserName $scpUser `
            -IdentityFile ([string]$Config.ScpIdentityFile) `
            -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
            -ConnectTimeoutSeconds 20 `
            -Config $Config
        if (-not $hostReachable) {
            Set-ScpConnectBackoff
            $skipMsg = ("SCP on lock skipped: {0}:{1} SSH handshake failed " +
                "(banner/kex timed out or refused). Backing off {2} min." -f `
                    $scpHost, $port, [int]$script:ScpConnectBackoffMinutes)
            if (Write-ScpConnectFailureThrottled -Message $skipMsg -Level 'WARN') {
                $null = Send-LoginTimeLoggerFailureAlert `
                    -Subject 'SCP connect failed' `
                    -Body $skipMsg `
                    -AlertKey 'scp-connect-failed' `
                    -Config $Config `
                    -ErrorLogPath $ErrorLogPath
            }
            return
        }

        # Hard cap: ConnectTimeout only covers TCP connect. A stalled transfer
        # previously blocked the monitor for hours (see Connection aborted after ~2.5h).
        # Scale with payload (~50 KiB/s floor + 60s slack) now that CSVs are included;
        # clamp 90..600.
        $totalBytes = [int64]0
        foreach ($bf in $files) {
            try {
                $totalBytes += [int64](Get-Item -LiteralPath $bf -Force).Length
            }
            catch { }
        }
        $scpTimeoutSeconds = 60 + [int][Math]::Ceiling($totalBytes / 51200.0)
        if ($scpTimeoutSeconds -lt 90) { $scpTimeoutSeconds = 90 }
        if ($scpTimeoutSeconds -gt 600) { $scpTimeoutSeconds = 600 }

        $maxAttempts = 3
        $attempt = 0
        $copyOk = $false
        $stdout = ''
        $stderr = ''
        $exitCode = -1
        $runTimedOut = $false

        while ($attempt -lt $maxAttempts -and -not $copyOk) {
            $attempt++
            # Do not name this $args (PowerShell automatic variable).
            $scpArgList = New-Object System.Collections.Generic.List[string]
            Add-ScpCommonSshOptions -ArgumentList $scpArgList `
                -IdentityFile ([string]$Config.ScpIdentityFile) `
                -Port $port `
                -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
                -ConnectTimeoutSeconds 45 `
                -VerboseSsh
            foreach ($f in $files) {
                $scpArgList.Add($f)
            }
            $scpArgList.Add($remoteTarget)

            Write-LoggerEvent ("SCP on lock: copying {0} file(s) to {1} (timeout {2}s, attempt {3}/{4}): {5}" -f `
                    $files.Count, $remoteTarget, $scpTimeoutSeconds, $attempt, $maxAttempts,
                ($files -join '; '))

            $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.out' -f [guid]::NewGuid().ToString('N'))
            $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.err' -f [guid]::NewGuid().ToString('N'))
            try {
                $argLine = $null
                if (Get-Command ConvertTo-ScpArgumentLine -ErrorAction SilentlyContinue) {
                    $argLine = ConvertTo-ScpArgumentLine -Arguments $scpArgList.ToArray()
                }
                elseif (Get-Command ConvertTo-StartProcessArgumentString -ErrorAction SilentlyContinue) {
                    $argLine = ConvertTo-StartProcessArgumentString -Argument $scpArgList.ToArray()
                }
                if ([string]::IsNullOrWhiteSpace($argLine)) {
                    $argLine = ($scpArgList | ForEach-Object {
                            if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
                        }) -join ' '
                }

                $run = Invoke-ScpProcessWithTimeout -ScpExe $scpExe -ArgumentList $argLine `
                    -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $scpTimeoutSeconds
                $stdout = ''
                $stderr = ''
                if (Test-Path -LiteralPath $outFile) {
                    $stdout = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
                }
                if (Test-Path -LiteralPath $errFile) {
                    $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
                }
                $exitCode = -1
                if ($null -ne $run.ExitCode) { $exitCode = [int]$run.ExitCode }
                $runTimedOut = [bool]$run.TimedOut

                if ($runTimedOut) {
                    break
                }
                if (-not (Test-ScpCopyFailed -ExitCode $exitCode -StdErr "$stderr" -TimedOut $false)) {
                    $copyOk = $true
                    break
                }
                if ((Test-ScpConnectFailure -StdErr "$stderr") -and $attempt -lt $maxAttempts) {
                    $null = Invoke-ScpOutboundAllowReconcile -Config $Config -Force
                    Write-LoggerEvent -Level WARN -Message (
                        "SCP on lock connect failed (attempt {0}); retrying in 5s." -f $attempt)
                    Start-Sleep -Seconds 5
                    continue
                }
                break
            }
            finally {
                Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
            }
        }

        if ($copyOk) {
            Clear-ScpConnectBackoff
            Write-LoggerEvent ("SCP on lock succeeded ({0} file(s)): {1}" -f $files.Count, ($files -join '; '))
            return
        }

        $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
        if ($null -ne $verboseExit) {
            $exitCode = $verboseExit
        }
        if ($runTimedOut) {
            $msg = ("SCP on lock timed out after {0}s (killed). target={1}; files={2}; stderr={3}; stdout={4}" -f `
                    $scpTimeoutSeconds, $remoteTarget, ($files -join '; '), ("$stderr").Trim(), ("$stdout").Trim())
        }
        else {
            $msg = ("SCP on lock failed (exit {0}). target={1}; files={2}; stderr={3}; stdout={4}" -f `
                    $exitCode, $remoteTarget, ($files -join '; '), ("$stderr").Trim(), ("$stdout").Trim())
            $badKeyAcl = '(?i)UNPROTECTED PRIVATE KEY|bad permissions|' +
                'Permissions for .+ are too open'
            if ("$stderr" -match $badKeyAcl) {
                $msg = $msg + ("`r`nPrivate key ACL is too open for SYSTEM scp. " +
                    "Re-run Install/Restart (Protect-ScpPrivateKeyFile) or: " +
                    "icacls `"{0}`" /inheritance:r && " +
                    "icacls `"{0}`" /grant:r SYSTEM:F" -f `
                        ([string]$Config.ScpIdentityFile))
            }
            elseif (Test-ScpAuthFailure -StdErr "$stderr") {
                $pub = Get-ScpPublicKeyText -IdentityPath $Config.ScpIdentityFile
                if (-not [string]::IsNullOrWhiteSpace($pub)) {
                    $msg = $msg + (
                        "`r`nRemote rejected public key auth. Append this line " +
                        "to {0}@host ~/.ssh/authorized_keys:`r`n{1}" -f `
                            $scpUser, $pub)
                }
                else {
                    $msg = $msg + (
                        "`r`nRemote rejected public key auth; ensure " +
                        'ScpIdentityFile.pub is in remote authorized_keys.')
                }
            }
        }

        $isConnectFail = Test-ScpConnectFailure -StdErr "$stderr"
        if ($isConnectFail) {
            Set-ScpConnectBackoff
            if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
                $diagPath = Join-Path $env:TEMP ('LoginTimeLogger-scp-fail-{0}.txt' -f [guid]::NewGuid().ToString('N'))
                try {
                    @(
                        $msg
                        ''
                        '--- scp stderr ---'
                        ("$stderr").Trim()
                        ''
                        '--- scp stdout ---'
                        ("$stdout").Trim()
                    ) | Set-Content -LiteralPath $diagPath -Encoding UTF8
                    $null = Send-LoginTimeLoggerFailureAlert `
                        -Subject 'SCP connect failed' `
                        -Body $msg `
                        -AlertKey 'scp-connect-failed' `
                        -Config $Config `
                        -ErrorLogPath $ErrorLogPath `
                        -ExtraAttachment @($diagPath)
                }
                finally {
                    Remove-Item -LiteralPath $diagPath -Force -ErrorAction SilentlyContinue
                }
            }
            return
        }

        # Non-connect failures: always log + alert (auth, mid-transfer, etc.).
        Write-LoggerEvent -Level WARN -Message $msg
        $diagPath = Join-Path $env:TEMP ('LoginTimeLogger-scp-fail-{0}.txt' -f [guid]::NewGuid().ToString('N'))
        try {
            @(
                $msg
                ''
                '--- scp stderr ---'
                ("$stderr").Trim()
                ''
                '--- scp stdout ---'
                ("$stdout").Trim()
            ) | Set-Content -LiteralPath $diagPath -Encoding UTF8
            $null = Send-ScpOnLockFailureAlert -Body $msg -Config $Config `
                -ErrorLogPath $ErrorLogPath -ExtraAttachment @($diagPath)
        }
        finally {
            Remove-Item -LiteralPath $diagPath -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $details = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'ScpOnLock' -Context 'SCP on lock failed'
        $null = Send-ScpOnLockFailureAlert -Body $details -Config $Config -ErrorLogPath $ErrorLogPath
    }
}

function Get-CurrentUnlockedTimeLogPath {
    <#
      Today's unlocked-time-yyyy-MM-dd.log under LogDirectory (local date).
    #>
    param([Parameter(Mandatory)]$Config)

    $logDir = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $logDir = [string]$Config.LogDirectory
    }
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        return ''
    }
    if (Get-Command Get-DailyLogPath -ErrorAction SilentlyContinue) {
        try {
            return (Get-DailyLogPath -LogDirectory $logDir -Date (Get-Date))
        }
        catch { }
    }
    return (Join-Path $logDir ('unlocked-time-{0:yyyy-MM-dd}.log' -f (Get-Date)))
}

function Get-ScpCommandsLocalPaths {
    <#
      Local dirs for remote commands.txt exchange:
        LogDirectory\commands\commands.txt       - downloaded from remote
        LogDirectory\commands-empty\commands.txt - 0-byte template uploaded back
    #>
    param([Parameter(Mandatory)]$Config)

    $logDir = [string]$Config.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDir)) {
        throw (New-Object System.Exception('LogDirectory is empty; cannot resolve commands paths.'))
    }
    $inboxDir = Join-Path $logDir 'commands'
    $emptyDir = Join-Path $logDir 'commands-empty'
    return [pscustomobject]@{
        InboxDirectory = $inboxDir
        InboxFile      = Join-Path $inboxDir 'commands.txt'
        EmptyDirectory = $emptyDir
        EmptyFile      = Join-Path $emptyDir 'commands.txt'
    }
}

function Ensure-ScpCommandsLocalLayout {
    <#
      Creates inbox/empty dirs and ensures the empty template is exactly 0 bytes.
    #>
    param([Parameter(Mandatory)]$Paths)

    foreach ($dir in @($Paths.InboxDirectory, $Paths.EmptyDirectory)) {
        if (-not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
    }

    $emptyPath = [string]$Paths.EmptyFile
    $needWrite = $true
    if (Test-Path -LiteralPath $emptyPath -PathType Leaf) {
        try {
            if ((Get-Item -LiteralPath $emptyPath -Force).Length -eq 0) {
                $needWrite = $false
            }
        }
        catch {
            $needWrite = $true
        }
    }
    if ($needWrite) {
        # No BOM / newline — true empty file for remote overwrite.
        [System.IO.File]::WriteAllBytes($emptyPath, [byte[]]@())
    }
}

function Test-ScpRemotePathMissing {
    <#
      True when scp stderr indicates the remote source file does not exist.
      Missing remote commands.txt is treated as success (no work).
    #>
    param([string]$StdErr = '')

    if ([string]::IsNullOrWhiteSpace($StdErr)) {
        return $false
    }
    return ($StdErr -match '(?i)No such file or directory') -or
        ($StdErr -match '(?i)not a regular file') -or
        ($StdErr -match '(?i)Cannot download non-regular file') -or
        ($StdErr -match '(?i)No such file\b')
}

function ConvertTo-ScpArgumentLine {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]]$Arguments
    )

    $argLine = $null
    if (Get-Command ConvertTo-StartProcessArgumentString -ErrorAction SilentlyContinue) {
        $argLine = ConvertTo-StartProcessArgumentString -Argument $Arguments
    }
    if ([string]::IsNullOrWhiteSpace($argLine)) {
        $argLine = ($Arguments | ForEach-Object {
                if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
            }) -join ' '
    }
    return [string]$argLine
}

function Write-ScpCommandsTrace {
    <#
      Append a set -x style line (+ ...) to the commands run log and service.log.
    #>
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = '{0} + {1}' -f $stamp, $Message
    try {
        $dir = Split-Path -Parent $LogPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and
            -not (Test-Path -LiteralPath $dir -PathType Container)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    }
    catch { }
    if (Get-Command Write-LoggerEvent -ErrorAction SilentlyContinue) {
        Write-LoggerEvent -Level $Level -Message $line
    }
}

function Resolve-ScpCommandsInstallContext {
    <#
      InstallRoot + AdminAppDirectory for remote update/restart commands.
    #>
    param([Parameter(Mandatory)]$Config)

    $installRoot = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$script:InstallRoot)) {
        $installRoot = [string]$script:InstallRoot
    }
    else {
        $pf = Join-Path $env:ProgramFiles 'LoginTimeLogger'
        if (Test-Path -LiteralPath (Join-Path $pf 'src\LoginTimeLogger.ps1')) {
            $installRoot = $pf
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:ScpOnLockScriptDir)) {
            $installRoot = Split-Path -Parent $script:ScpOnLockScriptDir
        }
    }

    $adminApp = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.AdministratorProfile)) {
        $adminApp = Join-Path ([string]$Config.AdministratorProfile) 'LoginTimeLogger'
    }

    return [pscustomobject]@{
        InstallRoot        = $installRoot
        AdminAppDirectory  = $adminApp
    }
}

function ConvertFrom-RemoteCumulativeTimeText {
    <#
      Parses HH:MM:SS (hours may exceed 24) or a whole-second integer.
      Returns $null when invalid.
    #>
    param([AllowNull()][string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }
    $trimmed = $Text.Trim()
    if ($trimmed -match '^(?<h>\d+):(?<m>[0-5]?\d):(?<s>[0-5]?\d)$') {
        try {
            return [double](
                ([int]$Matches['h'] * 3600) +
                ([int]$Matches['m'] * 60) +
                [int]$Matches['s'])
        }
        catch {
            return $null
        }
    }
    if ($trimmed -match '^\d+$') {
        try {
            return [double][int]$trimmed
        }
        catch {
            return $null
        }
    }
    return $null
}

function Format-RemoteCumulativeDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    if (Get-Command Format-Duration -ErrorAction SilentlyContinue) {
        return (Format-Duration -Seconds $Seconds)
    }
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    return ('{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds)
}

function New-RemoteCumulativeResetSpec {
    <#
      Build a pending reset spec from optional [[+|-]TIME] (empty = set to 0).
    #>
    param([AllowEmptyString()][string]$TimeArg = '')

    $trimmed = if ($null -eq $TimeArg) { '' } else { $TimeArg.Trim() }
    $mode = 'set'
    $deltaSeconds = 0.0
    $label = '0 (reset)'
    $eventTag = 'CUMULATIVE_RESET'

    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        # default: set to 0
    }
    elseif ($trimmed.StartsWith('+')) {
        $mode = 'add'
        $parsed = ConvertFrom-RemoteCumulativeTimeText -Text $trimmed.Substring(1)
        if ($null -eq $parsed) {
            throw ("Invalid reset +TIME '{0}' (use +HH:MM:SS or +seconds)." -f $trimmed)
        }
        $deltaSeconds = [double]$parsed
        $label = ('+{0}' -f (Format-RemoteCumulativeDuration -Seconds $deltaSeconds))
        $eventTag = 'CUMULATIVE_ADD'
    }
    elseif ($trimmed.StartsWith('-')) {
        $mode = 'subtract'
        $parsed = ConvertFrom-RemoteCumulativeTimeText -Text $trimmed.Substring(1)
        if ($null -eq $parsed) {
            throw ("Invalid reset -TIME '{0}' (use -HH:MM:SS or -seconds)." -f $trimmed)
        }
        $deltaSeconds = [double]$parsed
        $label = ('-{0}' -f (Format-RemoteCumulativeDuration -Seconds $deltaSeconds))
        $eventTag = 'CUMULATIVE_DEC'
    }
    else {
        $mode = 'set'
        $parsed = ConvertFrom-RemoteCumulativeTimeText -Text $trimmed
        if ($null -eq $parsed) {
            throw ("Invalid reset TIME '{0}' (use HH:MM:SS or seconds)." -f $trimmed)
        }
        $deltaSeconds = [double]$parsed
        $label = Format-RemoteCumulativeDuration -Seconds $deltaSeconds
        $eventTag = if ($deltaSeconds -le 0) { 'CUMULATIVE_RESET' } else { 'CUMULATIVE_SET' }
    }

    return [pscustomobject]@{
        Mode         = $mode
        DeltaSeconds = $deltaSeconds
        Label        = $label
        EventTag     = $eventTag
        RawTimeArg   = $trimmed
    }
}

function Write-ScpCommandsGitHeadOneline {
    <#
      Trace `git log -1 --oneline` for UpdateClonePath (commands.txt update).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TraceLogPath
    )

    Write-ScpCommandsTrace -LogPath $TraceLogPath -Message 'git log -1 --oneline'
    $repo = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.UpdateClonePath)) {
        $repo = [string]$Config.UpdateClonePath
    }
    if ([string]::IsNullOrWhiteSpace($repo) -or -not (Test-Path -LiteralPath $repo -PathType Container)) {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
            "git log -1 --oneline: UpdateClonePath missing or not a directory ('{0}')" -f $repo)
        return
    }

    $gitExe = $null
    if (Get-Command Find-GitExecutable -ErrorAction SilentlyContinue) {
        try { $gitExe = Find-GitExecutable } catch { $gitExe = $null }
    }
    if ([string]::IsNullOrWhiteSpace($gitExe)) {
        $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
        if ($cmd) { $gitExe = [string]$cmd.Source }
    }
    if ([string]::IsNullOrWhiteSpace($gitExe)) {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
            'git log -1 --oneline: git.exe not found')
        return
    }

    try {
        if (Get-Command Invoke-GitCommand -ErrorAction SilentlyContinue) {
            $gitResult = Invoke-GitCommand -GitExe $gitExe -RepoPath $repo `
                -Arguments @('log', '-1', '--oneline')
            $out = [string]$gitResult.Output
            if ([string]::IsNullOrWhiteSpace($out)) {
                $out = '(no output)'
            }
            foreach ($line in @(($out -split '\r?\n'))) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Message $line.TrimEnd()
            }
            if ([int]$gitResult.ExitCode -ne 0) {
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                    "git log -1 --oneline: exit {0}" -f $gitResult.ExitCode)
            }
        }
        else {
            $prevEap = $ErrorActionPreference
            $ErrorActionPreference = 'Continue'
            try {
                $output = & $gitExe -C $repo @('log', '-1', '--oneline') 2>&1
                $exitCode = [int]$LASTEXITCODE
            }
            finally {
                $ErrorActionPreference = $prevEap
            }
            foreach ($line in @($output | ForEach-Object { "$_" })) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Message $line.TrimEnd()
            }
            if ($exitCode -ne 0) {
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                    "git log -1 --oneline: exit {0}" -f $exitCode)
            }
        }
    }
    catch {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
            "git log -1 --oneline failed: {0}" -f $_.Exception.Message)
    }
}

function Queue-RemoteCumulativeReset {
    param(
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string]$TraceLogPath
    )

    if ($null -eq $script:PendingCumulativeResets) {
        $script:PendingCumulativeResets = New-Object System.Collections.ArrayList
    }
    [void]$script:PendingCumulativeResets.Add($Spec)
    Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
        "queue execute: reset mode={0} delta={1} tag={2}" -f `
            $Spec.Mode, $Spec.Label, $Spec.EventTag)
}

function Apply-PendingCumulativeResets {
    <#
      Apply queued remote reset specs to the live monitor $state (same poll,
      before Write-State). Writes CUMULATIVE_* lines to today's unlocked-time log.
      Returns the (possibly updated) state object.
    #>
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)]$Config
    )

    if ($null -eq $script:PendingCumulativeResets -or $script:PendingCumulativeResets.Count -eq 0) {
        return $State
    }

    $pending = @($script:PendingCumulativeResets.ToArray())
    $script:PendingCumulativeResets = New-Object System.Collections.ArrayList

    $quotaMinutes = 30
    try {
        if ($null -ne $Config.UnlockQuotaMinutes -and [int]$Config.UnlockQuotaMinutes -ge 1) {
            $quotaMinutes = [int]$Config.UnlockQuotaMinutes
        }
    }
    catch { }
    $quotaSeconds = [double]($quotaMinutes * 60)
    $today = (Get-Date).ToString('yyyy-MM-dd')
    $dailyPath = $null
    if (Get-Command Get-DailyLogPath -ErrorAction SilentlyContinue) {
        $dailyPath = Get-DailyLogPath -LogDirectory ([string]$Config.LogDirectory) -Date (Get-Date)
    }
    else {
        $dailyPath = Join-Path ([string]$Config.LogDirectory) ('unlocked-time-{0}.log' -f $today)
    }

    foreach ($spec in $pending) {
        if ($null -eq $spec) { continue }
        $previous = 0.0
        try { $previous = [double]$State.UnlockedSecondsToday } catch { $previous = 0.0 }

        switch ([string]$spec.Mode) {
            'add' { $newSeconds = $previous + [double]$spec.DeltaSeconds }
            'subtract' { $newSeconds = $previous - [double]$spec.DeltaSeconds }
            default { $newSeconds = [double]$spec.DeltaSeconds }
        }
        if ($newSeconds -lt 0) { $newSeconds = 0.0 }
        $newSeconds = [double][Math]::Floor($newSeconds)
        $newBucket = [int][Math]::Floor($newSeconds / $quotaSeconds)

        if (Get-Command ConvertTo-LoggerStateObject -ErrorAction SilentlyContinue) {
            $State = ConvertTo-LoggerStateObject -State $State -UnlockQuotaMinutes $quotaMinutes
        }
        $State.Date = $today
        $State.UnlockedSecondsToday = $newSeconds
        $State.LastUnlockQuotaBucket = $newBucket

        $prevText = Format-RemoteCumulativeDuration -Seconds $previous
        $newText = Format-RemoteCumulativeDuration -Seconds $newSeconds
        $line = ('{0:yyyy-MM-dd HH:mm:ss} | {1} | cumulative_today={2} | previous={3} | adjustment={4}' -f `
                (Get-Date), [string]$spec.EventTag, $newText, $prevText, [string]$spec.Label)
        try {
            if (Get-Command Write-DailyLogLine -ErrorAction SilentlyContinue) {
                Write-DailyLogLine -Path $dailyPath -Line $line
            }
            else {
                Add-Content -LiteralPath $dailyPath -Value $line -Encoding UTF8
            }
        }
        catch {
            Write-LoggerEvent -Level WARN -Message (
                "Remote reset: day-log append failed: {0}" -f $_.Exception.Message)
        }
        Write-LoggerEvent ("Remote reset applied: {0}" -f $line)
    }

    return $State
}

function Invoke-ScpRemoteCommandsFile {
    <#
      Read LogDirectory\commands\commands.txt line by line, interpret/execute
      supported commands (update, restart, reset, break), write a set -x style
      transcript, email the transcript, then delete the downloaded file.
      Returns: WantUpdate / WantRestart / WantBreak / ResetSpecs (terminating
      actions deferred until after remote empty-PUT and email).
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$InboxFile,
        [Parameter(Mandatory)][string]$TraceLogPath
    )

    $result = [pscustomobject]@{
        WantUpdate  = $false
        WantRestart = $false
        WantBreak   = $false
        ResetSpecs  = New-Object System.Collections.ArrayList
        RanAny      = $false
    }

    if (-not (Test-Path -LiteralPath $InboxFile -PathType Leaf)) {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
            "skip: inbox missing '{0}'" -f $InboxFile)
        return $result
    }

    $bytes = 0
    try { $bytes = [int64](Get-Item -LiteralPath $InboxFile -Force).Length } catch { }
    Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
        "open '{0}' ({1} byte(s))" -f $InboxFile, $bytes)

    if ($bytes -le 0) {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Message 'skip: empty commands.txt'
        return $result
    }

    $rawLines = @(Get-Content -LiteralPath $InboxFile -Encoding UTF8 -ErrorAction Stop)
    Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
        "read {0} line(s)" -f $rawLines.Count)

    $lineNo = 0
    foreach ($raw in $rawLines) {
        $lineNo++
        $line = if ($null -eq $raw) { '' } else { ([string]$raw).Trim() }
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
            "read line {0}: {1}" -f $lineNo, $(if ($line.Length -eq 0) { '(blank)' } else { $line }))

        if ($line.Length -eq 0) {
            Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                "interpret line {0}: skip blank" -f $lineNo)
            continue
        }
        if ($line.StartsWith('#')) {
            Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                "interpret line {0}: skip comment" -f $lineNo)
            continue
        }

        $tokens = @([regex]::Split($line, '\s+') | Where-Object { $_ -ne '' })
        if ($tokens.Count -eq 0) {
            continue
        }
        $verb = [string]$tokens[0]
        $args = @()
        if ($tokens.Count -gt 1) {
            $args = @($tokens[1..($tokens.Count - 1)])
        }
        $argText = if ($args.Count -gt 0) { ($args -join ' ') } else { '(none)' }
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
            "interpret line {0}: command='{1}' args={2}" -f $lineNo, $verb, $argText)

        $verbKey = $verb.ToLowerInvariant()
        switch ($verbKey) {
            'update' {
                $result.RanAny = $true
                $result.WantUpdate = $true
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                    "queue execute: update (force repo sync + publish; implies restart if changed)")
            }
            'restart' {
                $result.RanAny = $true
                $result.WantRestart = $true
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                    'queue execute: restart (deferred until after remote clear + email)')
            }
            'reset' {
                $timeArg = ''
                if ($args.Count -gt 0) {
                    $timeArg = [string]$args[0]
                }
                if ($args.Count -gt 1) {
                    Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                        "interpret line {0}: reset ignores extra args after TIME" -f $lineNo)
                }
                try {
                    $spec = New-RemoteCumulativeResetSpec -TimeArg $timeArg
                    $result.RanAny = $true
                    [void]$result.ResetSpecs.Add($spec)
                    Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                        "queue execute: reset {0}" -f $(
                            if ([string]::IsNullOrWhiteSpace($timeArg)) { '(to 0)' } else { $timeArg }))
                }
                catch {
                    Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                        "interpret line {0}: reset rejected: {1}" -f $lineNo, $_.Exception.Message)
                }
            }
            'break' {
                if ($args.Count -gt 0) {
                    Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                        "interpret line {0}: break ignores args (expected none)" -f $lineNo)
                }
                $result.RanAny = $true
                $result.WantBreak = $true
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
                    'queue execute: break (deferred dialog + lock on next monitor poll)')
                if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) {
                    Write-DebugLog -Source 'Break' -Message (
                        "commands.txt line {0}: verb=break queued (WantBreak=true)" -f $lineNo)
                }
            }
            default {
                Write-ScpCommandsTrace -LogPath $TraceLogPath -Level WARN -Message (
                    "interpret line {0}: unknown command '{1}' (ignored)" -f $lineNo, $verb)
            }
        }
    }

    if ($result.WantUpdate -and $result.WantRestart) {
        Write-ScpCommandsTrace -LogPath $TraceLogPath -Message (
            'note: both update and restart queued; update will restart when it applies changes, else restart runs after')
    }

    return $result
}

function Send-ScpCommandsRunAlert {
    <#
      Email the commands run transcript (not treated as a failure).
      Prefer Send-LoginTimeCommandsRunSmtpAlert (Common-Smtp) so update/publish
      can reload that helper from disk before sending.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TraceLogPath,
        [Parameter(Mandatory)][string]$Body
    )

    if (Get-Command Send-LoginTimeCommandsRunSmtpAlert -ErrorAction SilentlyContinue) {
        return (Send-LoginTimeCommandsRunSmtpAlert `
                -Config $Config `
                -TraceLogPath $TraceLogPath `
                -Body $Body)
    }

    if (-not (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue)) {
        return $false
    }

    $traceText = ''
    if (-not [string]::IsNullOrWhiteSpace($TraceLogPath) -and
        (Test-Path -LiteralPath $TraceLogPath -PathType Leaf)) {
        try {
            $traceText = [string](Get-Content -LiteralPath $TraceLogPath -Raw -Encoding UTF8 `
                    -ErrorAction Stop)
        }
        catch {
            $traceText = ('(could not read trace log: {0})' -f $_.Exception.Message)
        }
    }
    if ([string]::IsNullOrWhiteSpace($traceText)) {
        $traceText = '(commands-run log empty or missing)'
    }

    $fullBody = @(
        '--- commands-run log (set -x style) ---'
        $traceText.TrimEnd()
        '--- end commands-run log ---'
        ''
        $Body
    ) -join [Environment]::NewLine

    $stamp = [datetime]::UtcNow.ToString('yyyyMMddTHHmmss')
    $attachments = New-Object System.Collections.Generic.List[string]
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $svc = Join-Path ([string]$Config.LogDirectory) 'service.log'
        if (Test-Path -LiteralPath $svc) { $attachments.Add($svc) }
    }

    return (Send-LoginTimeSmtpAlert `
            -Subject 'Remote commands executed' `
            -Body $fullBody `
            -AlertKey ('scp-commands-ran-{0}' -f $stamp) `
            -Attachment @($attachments))
}

function Send-ScpCommandsDeferredRunAlert {
    <#
      Send the pending commands-run email using script:ScpCommandsTraceLogPath /
      script:ScpCommandsEmailBody (set before a remote "update" that may restart).
      Never sends when the downloaded commands.txt was empty (size=0).
    #>
    param([Parameter(Mandatory)]$Config)

    $trace = [string]$script:ScpCommandsTraceLogPath
    $body = [string]$script:ScpCommandsEmailBody
    if ([string]::IsNullOrWhiteSpace($trace) -or [string]::IsNullOrWhiteSpace($body)) {
        return $false
    }
    if ($null -ne $script:ScpCommandsDownloadedBytes -and
        [int64]$script:ScpCommandsDownloadedBytes -le 0) {
        Write-ScpCommandsTrace -LogPath $trace -Message (
            'email: skipped (downloaded commands.txt size=0)')
        $script:ScpCommandsEmailBody = $null
        return $false
    }
    if (-not (Get-Command Send-ScpCommandsRunAlert -ErrorAction SilentlyContinue)) {
        return $false
    }

    Write-ScpCommandsTrace -LogPath $trace -Message 'email: sending commands run transcript'
    $sent = Send-ScpCommandsRunAlert -Config $Config -TraceLogPath $trace -Body $body
    Write-ScpCommandsTrace -LogPath $trace -Message ("email: sent={0}" -f [bool]$sent)
    $script:ScpCommandsEmailBody = $null
    return [bool]$sent
}

function Invoke-ScpCommandsFatal {
    param(
        [Parameter(Mandatory)][string]$Message,
        [string]$Context = 'SCP commands exchange'
    )

    if (Get-Command Write-FatalError -ErrorAction SilentlyContinue) {
        $null = Write-FatalError -Message $Message -Context $Context `
            -Source 'ScpCommands' -NoThrow
    }
    else {
        Write-LoggerEvent -Level ERROR -Message ("{0}: {1}" -f $Context, $Message)
    }
}

function Invoke-ScpCommandsFileExchange {
    <#
      Own 1-minute monitor timer (same OpenSSH Process path as Copy-LogsViaScp).
      Short ConnectTimeout so a down remote cannot stall ~3 minutes:
        1) download ScpRemoteDirectory/commands.txt -> LogDirectory\commands\
           (missing remote file is OK; connect/banner -> throttled WARN)
        2) upload 0-byte LogDirectory\commands-empty\commands.txt to overwrite remote
        3) read/interpret/execute lines (update, restart, reset, break); set -x style log
        4) email the run log
        5) delete the downloaded commands.txt
        6) run deferred update and/or restart (may exit the process)
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$ScpExe
    )

    $paths = Get-ScpCommandsLocalPaths -Config $Config
    Ensure-ScpCommandsLocalLayout -Paths $paths

    $traceStamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $traceLogPath = Join-Path $paths.InboxDirectory (
        'commands-run-{0}.log' -f $traceStamp)

    $remoteDir = ([string]$Config.ScpRemoteDirectory).Trim()
    if (-not $remoteDir.EndsWith('/')) {
        $remoteDir = $remoteDir + '/'
    }
    $scpHost = ([string]$Config.ScpHost).Trim()
    $scpUser = ([string]$Config.ScpUser).Trim()
    $remoteFile = '{0}@{1}:{2}commands.txt' -f $scpUser, $scpHost, $remoteDir

    $port = 22
    if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
        $port = [int]$Config.ScpPort
    }

    Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
        "begin commands exchange; remote={0}; inbox={1}" -f $remoteFile, $paths.InboxFile)

    # Same OpenSSH Process path as Copy-LogsViaScp / BHistory, but keep this
    # cycle short: tiny file, 1-minute cadence — do not burn 3x45s (~3 min).
    $commandsConnectTimeoutSec = 15
    $commandsProcessTimeoutSec = 40

    $downloaded = $false
    $downloadedBytes = [int64]0
    $script:ScpCommandsDownloadedBytes = [int64]0
    $remoteMissing = $false

    # --- GET remote commands.txt -> local inbox (retry connect timeouts) ---
    $getOk = $false
    $getAttempt = 0
    $getMaxAttempts = 2
    while ($getAttempt -lt $getMaxAttempts -and -not $getOk) {
        $getAttempt++
        $getArgs = New-Object System.Collections.Generic.List[string]
        Add-ScpCommonSshOptions -ArgumentList $getArgs `
            -IdentityFile ([string]$Config.ScpIdentityFile) `
            -Port $port `
            -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
            -ConnectTimeoutSeconds $commandsConnectTimeoutSec `
            -VerboseSsh
        $getArgs.Add($remoteFile)
        $getArgs.Add([string]$paths.InboxFile)

        Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
            "scp get attempt {0}/{1}: {2} {3}" -f $getAttempt, $getMaxAttempts, $remoteFile, $paths.InboxFile)

        $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-commands-get-{0}.out' -f [guid]::NewGuid().ToString('N'))
        $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-commands-get-{0}.err' -f [guid]::NewGuid().ToString('N'))
        try {
            $argLine = ConvertTo-ScpArgumentLine -Arguments $getArgs.ToArray()
            $run = Invoke-ScpProcessWithTimeout -ScpExe $ScpExe -ArgumentList $argLine `
                -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $commandsProcessTimeoutSec
            $stderr = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
            }

            $getFailed = [bool]$run.TimedOut -or
                (Test-ScpCopyFailed -ExitCode $run.ExitCode -StdErr "$stderr" -TimedOut $false)
            # Banner/kex hangs: process timeout and/or connect patterns in -v stderr.
            # WARN+backoff (not FATAL) so flaky LAN SSH does not email every minute.
            if ($getFailed -and (
                    [bool]$run.TimedOut -or (Test-ScpConnectFailure -StdErr "$stderr"))) {
                if ($getAttempt -lt $getMaxAttempts) {
                    $null = Invoke-ScpOutboundAllowReconcile -Config $Config -Force
                    Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                        "scp get connect/timeout failed (attempt {0}); retrying in 2s" -f $getAttempt)
                    Start-Sleep -Seconds 2
                    continue
                }
                $reportedExit = $run.ExitCode
                if ($run.TimedOut) { $reportedExit = 'timeout' }
                else {
                    $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
                    if ($null -ne $verboseExit) { $reportedExit = $verboseExit }
                }
                $msg = ("SCP commands download connect failed (exit {0}). remote={1}; stderr={2}" -f `
                        $reportedExit, $remoteFile, ("$stderr").Trim())
                Set-ScpConnectBackoff
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message $msg
                if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
                    $null = Send-LoginTimeLoggerFailureAlert `
                        -Subject 'SCP connect failed' `
                        -Body $msg `
                        -AlertKey 'scp-connect-failed' `
                        -Config $Config
                }
                return
            }
            if ($getFailed -and (Test-ScpAuthFailure -StdErr "$stderr")) {
                $msg = ("SCP commands download auth failed. remote={0}; stderr={1}" -f `
                        $remoteFile, ("$stderr").Trim())
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message $msg
                Invoke-ScpCommandsFatal -Message $msg -Context 'SCP commands download'
                return
            }
            if ($getFailed) {
                if (Test-ScpRemotePathMissing -StdErr "$stderr") {
                    $remoteMissing = $true
                    $getOk = $true
                    Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                        "remote commands.txt not present (OK). remote={0}" -f $remoteFile)
                    break
                }
                $reportedExit = $run.ExitCode
                $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
                if ($null -ne $verboseExit) { $reportedExit = $verboseExit }
                $msg = ("SCP commands download failed (exit {0}). remote={1}; stderr={2}" -f `
                        $reportedExit, $remoteFile, ("$stderr").Trim())
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message $msg
                Invoke-ScpCommandsFatal -Message $msg -Context 'SCP commands download'
                return
            }

            $getOk = $true
            Clear-ScpConnectBackoff
            $downloaded = $true
            $downloadedBytes = [int64]0
            try {
                if (Test-Path -LiteralPath $paths.InboxFile -PathType Leaf) {
                    $downloadedBytes = [int64](Get-Item -LiteralPath $paths.InboxFile -Force).Length
                }
            }
            catch { }
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                "downloaded OK ({0} byte(s)) -> {1}" -f $downloadedBytes, $paths.InboxFile)
            $script:ScpCommandsDownloadedBytes = $downloadedBytes
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $getOk) {
        $msg = ("SCP commands download failed after {0} attempt(s). remote={1}" -f `
                $getMaxAttempts, $remoteFile)
        Set-ScpConnectBackoff
        Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message $msg
        if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
            $null = Send-LoginTimeLoggerFailureAlert `
                -Subject 'SCP connect failed' `
                -Body $msg `
                -AlertKey 'scp-connect-failed' `
                -Config $Config
        }
        return
    }

    # --- PUT empty immediately after download (clear remote before local processing) ---
    Ensure-ScpCommandsLocalLayout -Paths $paths
    $putOk = $false
    $putAttempt = 0
    $putMaxAttempts = 2
    while ($putAttempt -lt $putMaxAttempts -and -not $putOk) {
        $putAttempt++
        $putArgs = New-Object System.Collections.Generic.List[string]
        Add-ScpCommonSshOptions -ArgumentList $putArgs `
            -IdentityFile ([string]$Config.ScpIdentityFile) `
            -Port $port `
            -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
            -ConnectTimeoutSeconds $commandsConnectTimeoutSec `
            -VerboseSsh
        $putArgs.Add([string]$paths.EmptyFile)
        $putArgs.Add($remoteFile)

        Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
            "scp put empty attempt {0}/{1}: {2} -> {3}" -f `
                $putAttempt, $putMaxAttempts, $paths.EmptyFile, $remoteFile)

        $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-commands-put-{0}.out' -f [guid]::NewGuid().ToString('N'))
        $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-commands-put-{0}.err' -f [guid]::NewGuid().ToString('N'))
        try {
            $argLine = ConvertTo-ScpArgumentLine -Arguments $putArgs.ToArray()
            $run = Invoke-ScpProcessWithTimeout -ScpExe $ScpExe -ArgumentList $argLine `
                -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $commandsProcessTimeoutSec
            $stderr = ''
            if (Test-Path -LiteralPath $errFile) {
                $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
            }

            $putFailed = [bool]$run.TimedOut -or
                (Test-ScpCopyFailed -ExitCode $run.ExitCode -StdErr "$stderr" -TimedOut $false)
            if ($putFailed -and (
                    [bool]$run.TimedOut -or (Test-ScpConnectFailure -StdErr "$stderr"))) {
                if ($putAttempt -lt $putMaxAttempts) {
                    $null = Invoke-ScpOutboundAllowReconcile -Config $Config -Force
                    Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                        "scp put connect/timeout failed (attempt {0}); retrying in 2s" -f $putAttempt)
                    Start-Sleep -Seconds 2
                    continue
                }
                $reportedExit = $run.ExitCode
                if ($run.TimedOut) { $reportedExit = 'timeout' }
                else {
                    $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
                    if ($null -ne $verboseExit) { $reportedExit = $verboseExit }
                }
                $msg = ("SCP commands empty upload failed (exit {0}). remote={1}; stderr={2}" -f `
                        $reportedExit, $remoteFile, ("$stderr").Trim())
                Set-ScpConnectBackoff
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message $msg
                if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
                    $null = Send-LoginTimeLoggerFailureAlert `
                        -Subject 'SCP connect failed' `
                        -Body $msg `
                        -AlertKey 'scp-connect-failed' `
                        -Config $Config
                }
                return
            }
            if ($putFailed) {
                $reportedExit = $run.ExitCode
                $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
                if ($null -ne $verboseExit) { $reportedExit = $verboseExit }
                $msg = ("SCP commands empty upload failed (exit {0}). remote={1}; stderr={2}" -f `
                        $reportedExit, $remoteFile, ("$stderr").Trim())
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message $msg
                Invoke-ScpCommandsFatal -Message $msg -Context 'SCP commands empty upload'
                return
            }
            $putOk = $true
            Clear-ScpConnectBackoff
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $putOk) {
        $msg = ("SCP commands empty upload failed after {0} attempt(s). remote={1}" -f `
                $putMaxAttempts, $remoteFile)
        Set-ScpConnectBackoff
        Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message $msg
        if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
            $null = Send-LoginTimeLoggerFailureAlert `
                -Subject 'SCP connect failed' `
                -Body $msg `
                -AlertKey 'scp-connect-failed' `
                -Config $Config
        }
        return
    }
    Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
        "remote commands.txt cleared (empty upload OK) -> {0}" -f $remoteFile)

    # Empty download: clear local inbox, never interpret or email.
    if ($downloaded -and $downloadedBytes -le 0) {
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
            'email: skipped (downloaded commands.txt size=0)')
        if (Test-Path -LiteralPath $paths.InboxFile -PathType Leaf) {
            try {
                Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                    "rm '{0}'" -f $paths.InboxFile)
                Remove-Item -LiteralPath $paths.InboxFile -Force -ErrorAction Stop
                Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'rm: OK'
            }
            catch {
                Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                    "rm failed: {0}" -f $_.Exception.Message)
            }
        }
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'end commands exchange'
        $script:ScpCommandsDownloadedBytes = $null
        $script:ScpCommandsEmailBody = $null
        $script:ScpCommandsTraceLogPath = $null
        return
    }

    $cmdResult = [pscustomobject]@{
        WantUpdate  = $false
        WantRestart = $false
        WantBreak   = $false
        ResetSpecs  = New-Object System.Collections.ArrayList
        RanAny      = $false
    }
    if ($downloaded -and -not $remoteMissing -and $downloadedBytes -gt 0) {
        try {
            $cmdResult = Invoke-ScpRemoteCommandsFile `
                -Config $Config `
                -InboxFile ([string]$paths.InboxFile) `
                -TraceLogPath $traceLogPath
        }
        catch {
            $errMsg = $_.Exception.Message
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message (
                "command file processing failed: {0}" -f $errMsg)
            Invoke-ScpCommandsFatal -Message $errMsg -Context 'SCP commands interpret/execute'
            # Still email + delete local below when possible.
        }
    }

    $resetCount = 0
    try {
        if ($null -ne $cmdResult.ResetSpecs) {
            $resetCount = [int]$cmdResult.ResetSpecs.Count
        }
    }
    catch { $resetCount = 0 }

    # Delete downloaded commands.txt (always when present) before deferred actions.
    if (Test-Path -LiteralPath $paths.InboxFile -PathType Leaf) {
        try {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                "rm '{0}'" -f $paths.InboxFile)
            Remove-Item -LiteralPath $paths.InboxFile -Force -ErrorAction Stop
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'rm: OK'
        }
        catch {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                "rm failed: {0}" -f $_.Exception.Message)
        }
    }

    # Deferred actions (after remote clear + local delete).
    # reset: queue for the monitor poll loop (applies to live $state before Write-State).
    # Do not wrap List[object] in @(...): that throws ArgumentException under PS 5.1 StrictMode.
    $resetSpecsEnum = @()
    if ($null -ne $cmdResult.PSObject.Properties['ResetSpecs'] -and $null -ne $cmdResult.ResetSpecs) {
        if ($cmdResult.ResetSpecs -is [System.Collections.ArrayList] -or
            $cmdResult.ResetSpecs -is [System.Array]) {
            $resetSpecsEnum = @($cmdResult.ResetSpecs)
        }
        elseif ($cmdResult.ResetSpecs.PSObject.Methods['ToArray']) {
            $resetSpecsEnum = @($cmdResult.ResetSpecs.ToArray())
        }
        else {
            $resetSpecsEnum = @($cmdResult.ResetSpecs)
        }
    }
    foreach ($spec in $resetSpecsEnum) {
        if ($null -eq $spec) { continue }
        try {
            Queue-RemoteCumulativeReset -Spec $spec -TraceLogPath $traceLogPath
        }
        catch {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                "execute reset queue failed: {0}" -f $_.Exception.Message)
        }
    }

    # break: queue for the monitor poll loop (dialog + lock; after any resets).
    # Skip when the target session is already locked — still record in the
    # commands-run transcript so the run email reports the skip.
    $breakQueued = $false
    $breakSkippedLocked = $false
    if ($null -ne $cmdResult.PSObject.Properties['WantBreak'] -and [bool]$cmdResult.WantBreak) {
        $sessionUnlocked = $true
        try {
            if (('SessionQuery' -as [type]) -and
                -not [string]::IsNullOrWhiteSpace([string]$Config.TargetUsername)) {
                $sessionUnlocked = [bool][SessionQuery]::IsUserUnlocked([string]$Config.TargetUsername)
            }
        }
        catch {
            # Probe failed: keep legacy behavior (queue break).
            $sessionUnlocked = $true
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                "break lock-state probe failed; queueing anyway: {0}" -f $_.Exception.Message)
        }

        if (-not $sessionUnlocked) {
            $breakSkippedLocked = $true
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                ("execute: break ignored - target '{0}' session already locked " +
                    '(no dialog); email still sent') -f $Config.TargetUsername)
            if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) {
                Write-DebugLog -Source 'Break' -Message (
                    "break ignored: session already locked for '{0}'" -f $Config.TargetUsername)
            }
        }
        else {
            $script:PendingBreakRequested = $true
            $script:PendingBreakAttempts = 0
            $breakQueued = $true
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                'execute: break queued for next monitor poll (dialog + lock)')
            if (Get-Command Write-DebugLog -ErrorAction SilentlyContinue) {
                Write-DebugLog -Source 'Break' -Message (
                    'PendingBreakRequested=true (commands exchange); will Apply-PendingRemoteBreak on poll')
            }
        }
    }

    # Refresh summary lines so the email body matches the queue/skip decision.
    $emailBody = @(
        'LoginTimeLogger remote commands.txt was processed.'
        ''
        ('Remote: {0}' -f $remoteFile)
        ('Inbox: {0}' -f $paths.InboxFile)
        ('Trace: {0}' -f $traceLogPath)
        ('Downloaded: {0}' -f $downloaded)
        ('RemoteMissing: {0}' -f $remoteMissing)
        ('WantUpdate: {0}' -f $cmdResult.WantUpdate)
        ('WantRestart: {0}' -f $cmdResult.WantRestart)
        ('WantBreak: {0}' -f $(
            if ($null -ne $cmdResult.PSObject.Properties['WantBreak']) {
                [bool]$cmdResult.WantBreak
            }
            else { $false }))
        ('BreakQueued: {0}' -f $breakQueued)
        ('BreakSkippedAlreadyLocked: {0}' -f $breakSkippedLocked)
        ('ResetCount: {0}' -f $resetCount)
    ) -join [Environment]::NewLine

    # When "update" will run, defer email until after the repo sync so the
    # inlined transcript includes `git log -1 --oneline` of the new HEAD.
    $deferEmailForUpdate = [bool]$cmdResult.WantUpdate -and [bool]$Config.UpdateEnabled
    if ($downloaded -and $downloadedBytes -gt 0 -and -not $deferEmailForUpdate) {
        try {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'email: sending commands run transcript'
            $sent = Send-ScpCommandsRunAlert -Config $Config -TraceLogPath $traceLogPath -Body $emailBody
            Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                "email: sent={0}" -f [bool]$sent)
        }
        catch {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                "email: failed: {0}" -f $_.Exception.Message)
        }
    }
    elseif ($downloaded -and $downloadedBytes -le 0) {
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
            'email: skipped (downloaded commands.txt size=0)')
    }
    elseif ($deferEmailForUpdate) {
        $script:ScpCommandsEmailBody = $emailBody
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
            'email: deferred until after update (to include git log -1 --oneline)')
    }

    $ctx = Resolve-ScpCommandsInstallContext -Config $Config
    if ($cmdResult.WantUpdate) {
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'execute: update'
        if (-not [bool]$Config.UpdateEnabled) {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                'execute update: skipped (UpdateEnabled=false)')
        }
        elseif ([string]::IsNullOrWhiteSpace($ctx.InstallRoot) -or
            [string]::IsNullOrWhiteSpace($ctx.AdminAppDirectory)) {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message (
                'execute update: InstallRoot/AdminAppDirectory unresolved')
            Invoke-ScpCommandsFatal -Message (
                'Cannot run remote update: InstallRoot/AdminAppDirectory unresolved.') `
                -Context 'SCP commands update'
        }
        elseif (-not (Get-Command Invoke-LoginTimeLoggerUpdateCheck -ErrorAction SilentlyContinue)) {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message (
                'execute update: Invoke-LoginTimeLoggerUpdateCheck not loaded')
            Invoke-ScpCommandsFatal -Message (
                'Cannot run remote update: Invoke-LoginTimeLoggerUpdateCheck not loaded.') `
                -Context 'SCP commands update'
        }
        else {
            # May exit 0 after a successful sync+publish (Restart-LoginTimeLoggerProcess).
            # Update-Check logs `git log -1 --oneline` and emails after the repo update.
            $script:ScpCommandsTraceLogPath = $traceLogPath
            $script:ScpCommandsEmailBody = $emailBody
            $updateEmailSent = $false
            try {
                Invoke-LoginTimeLoggerUpdateCheck `
                    -Config $Config `
                    -InstallRoot $ctx.InstallRoot `
                    -AdminAppDirectory $ctx.AdminAppDirectory `
                    -Force
                Write-ScpCommandsTrace -LogPath $traceLogPath -Message (
                    'execute update: returned (no restart; already current or postponed)')
                # No repo change / no restart: still send the deferred commands email.
                if ($downloaded -and $downloadedBytes -gt 0 -and
                    -not [string]::IsNullOrWhiteSpace([string]$script:ScpCommandsEmailBody)) {
                    try {
                        $null = Send-ScpCommandsDeferredRunAlert -Config $Config
                        $updateEmailSent = $true
                    }
                    catch {
                        Write-ScpCommandsTrace -LogPath $traceLogPath -Level WARN -Message (
                            "email: failed: {0}" -f $_.Exception.Message)
                    }
                }
            }
            finally {
                if (-not $updateEmailSent -and
                    $downloaded -and $downloadedBytes -gt 0 -and
                    -not [string]::IsNullOrWhiteSpace([string]$script:ScpCommandsEmailBody)) {
                    # Update returned without restart (or failed before exit): still email.
                    try { $null = Send-ScpCommandsDeferredRunAlert -Config $Config } catch { }
                }
                $script:ScpCommandsTraceLogPath = $null
                $script:ScpCommandsEmailBody = $null
            }
        }

        # Flush deferred email when update was skipped before Invoke (not an elseif —
        # a trailing elseif after else is invalid and throws at runtime).
        if ($downloaded -and $downloadedBytes -gt 0 -and
            -not [string]::IsNullOrWhiteSpace([string]$script:ScpCommandsEmailBody)) {
            try { $null = Send-ScpCommandsDeferredRunAlert -Config $Config } catch { }
            $script:ScpCommandsEmailBody = $null
        }
    }

    if ($cmdResult.WantRestart) {
        Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'execute: restart'
        if ([string]::IsNullOrWhiteSpace($ctx.InstallRoot) -or
            [string]::IsNullOrWhiteSpace([string]$Config.ConfigPath)) {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message (
                'execute restart: InstallRoot/ConfigPath unresolved')
            Invoke-ScpCommandsFatal -Message (
                'Cannot run remote restart: InstallRoot/ConfigPath unresolved.') `
                -Context 'SCP commands restart'
            return
        }
        if (-not (Get-Command Restart-LoginTimeLoggerProcess -ErrorAction SilentlyContinue)) {
            Write-ScpCommandsTrace -LogPath $traceLogPath -Level ERROR -Message (
                'execute restart: Restart-LoginTimeLoggerProcess not loaded')
            Invoke-ScpCommandsFatal -Message (
                'Cannot run remote restart: Restart-LoginTimeLoggerProcess not loaded.') `
                -Context 'SCP commands restart'
            return
        }
        # Exits the process.
        Restart-LoginTimeLoggerProcess `
            -ConfigPath ([string]$Config.ConfigPath) `
            -InstallRoot $ctx.InstallRoot
    }

    Write-ScpCommandsTrace -LogPath $traceLogPath -Message 'end commands exchange'
}

function Invoke-ScpBHistoryCopy {
    <#
    .SYNOPSIS
      Every interval: for every op/ch profile BH DB, run
      Convert-LogBhToCsv.ps1 -PreviousDays 1 into
      log-history-op-<profile>-YYYY-MM-DD.csv /
      log-history-ch-<profile>-YYYY-MM-DD.csv under LogDirectory\bhist,
      SCP all of today's those CSVs when present, and upload today's
      unlocked-time-*.log. Remote commands.txt exchange runs on its own
      1-minute timer in the monitor (not here). Failures are logged; they
      do not stop the monitor.
    #>
    param(
        [Parameter(Mandatory)]$Config
    )

    if (-not (Test-ScpEndpointConfigured -Config $Config)) {
        return
    }

    $uploadFiles = New-Object System.Collections.Generic.List[string]
    $includeBHistory = $false
    try {
        $scpExe = Find-ScpExecutable
        if (-not $scpExe) {
            Write-LoggerEvent -Level WARN -Message 'SCP BHistory skipped: scp.exe not found.'
            return
        }
        if (-not (Test-Path -LiteralPath $Config.ScpIdentityFile)) {
            Write-LoggerEvent -Level WARN -Message (
                "SCP BHistory skipped: identity file missing: {0}" -f $Config.ScpIdentityFile)
            return
        }

        try {
            Protect-ScpPrivateKeyFile -IdentityPath ([string]$Config.ScpIdentityFile)
        }
        catch {
            Write-LoggerEvent -Level WARN -Message (
                "SCP identity ACL harden failed: {0}" -f $_.Exception.Message)
        }

        if ($null -eq $script:LastBHistoryStateByLeaf) {
            $script:LastBHistoryStateByLeaf = @{}
        }

        $sources = @(Get-BHistorySources -TargetUsername ([string]$Config.TargetUsername))
        if ($sources.Count -eq 0) {
            $nowMiss = [datetime]::UtcNow
            $warnMiss = $true
            if ($script:LastBHistoryMissingWarnUtc -is [datetime]) {
                $warnMiss = (($nowMiss - $script:LastBHistoryMissingWarnUtc).TotalMinutes -ge 60)
            }
            if ($warnMiss) {
                $script:LastBHistoryMissingWarnUtc = $nowMiss
                Write-LoggerEvent -Level WARN -Message (
                    'SCP BHistory: History file not found under known profile/install locations.')
            }
        }

        # Always convert (today's visits grow); upload CSVs only when they exist.
        $csvFiles = @(New-BHistoryCsvExports -Config $Config)
        foreach ($csv in $csvFiles) {
            if (-not [string]::IsNullOrWhiteSpace([string]$csv) -and (Test-Path -LiteralPath ([string]$csv))) {
                $uploadFiles.Add([string]$csv)
                $includeBHistory = $true
            }
        }

        $dailyPath = Get-CurrentUnlockedTimeLogPath -Config $Config
        if (-not [string]::IsNullOrWhiteSpace($dailyPath) -and (Test-Path -LiteralPath $dailyPath)) {
            $uploadFiles.Add($dailyPath)
        }

        $remoteDir = ([string]$Config.ScpRemoteDirectory).Trim()
        if (-not $remoteDir.EndsWith('/')) {
            $remoteDir = $remoteDir + '/'
        }
        $scpHost = ([string]$Config.ScpHost).Trim()
        $scpUser = ([string]$Config.ScpUser).Trim()
        $remoteTarget = '{0}@{1}:{2}' -f $scpUser, $scpHost, $remoteDir

        $port = 22
        if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
            $port = [int]$Config.ScpPort
        }

        # Backoff after recent SSH banner/kex failures so a flaky remote does not
        # burn 3x ConnectTimeout every 1-minute cycle (and spam SMTP).
        if (Test-ScpConnectBackoffActive) {
            $remain = [int][Math]::Ceiling(
                ($script:ScpConnectBackoffUntilUtc - [datetime]::UtcNow).TotalMinutes)
            Write-LoggerEvent -Level WARN -Message (
                "SCP BHistory/daily skipped: connect backoff active (~{0} min left after SSH handshake failures)." -f `
                    $remain)
            $hostReachable = $false
        }
        else {
            # OpenSSH handshake only — .NET TcpClient can false-fail while scp works.
            $hostReachable = Test-ScpRemoteReady `
                -HostName $scpHost `
                -Port $port `
                -UserName $scpUser `
                -IdentityFile ([string]$Config.ScpIdentityFile) `
                -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
                -ConnectTimeoutSeconds 20 `
                -Config $Config
            if (-not $hostReachable) {
                Set-ScpConnectBackoff
                $skipMsg = ("SCP BHistory/daily skipped: {0}:{1} SSH handshake failed " +
                    "(banner/kex timed out or refused). Backing off {2} min." -f `
                        $scpHost, $port, [int]$script:ScpConnectBackoffMinutes)
                if (Write-ScpConnectFailureThrottled -Message $skipMsg -Level 'WARN') {
                    $null = Send-LoginTimeLoggerFailureAlert `
                        -Subject 'SCP connect failed' `
                        -Body $skipMsg `
                        -AlertKey 'scp-connect-failed' `
                        -Config $Config
                }
                # commands.txt keeps its own 1-minute timer outside this function.
            }
        }

        if ($uploadFiles.Count -gt 0 -and $hostReachable) {
            # Upload daily log first (small/fast), then BHistory CSVs separately.
            $dailyFiles = New-Object System.Collections.Generic.List[string]
            $historyFiles = New-Object System.Collections.Generic.List[string]
            foreach ($f in $uploadFiles) {
                $leaf = Split-Path -Leaf $f
                if ($leaf -like 'unlocked-time-*.log') {
                    $dailyFiles.Add($f)
                }
                else {
                    $historyFiles.Add($f)
                }
            }

            $uploadBatches = @(
                @{ Name = 'daily'; Files = @($dailyFiles); TimeoutSeconds = 90 }
                @{ Name = 'BHistory'; Files = @($historyFiles); TimeoutSeconds = 0 }
            )

            foreach ($batch in $uploadBatches) {
                $batchFiles = @($batch.Files)
                if ($batchFiles.Count -eq 0) {
                    continue
                }

                $scpTimeoutSeconds = [int]$batch.TimeoutSeconds
                if ($scpTimeoutSeconds -le 0) {
                    # Scale with payload size (~50 KiB/s floor + 60s slack), clamp 120..600.
                    $totalBytes = [int64]0
                    foreach ($bf in $batchFiles) {
                        try {
                            $totalBytes += [int64](Get-Item -LiteralPath $bf -Force).Length
                        }
                        catch { }
                    }
                    $scpTimeoutSeconds = 60 + [int][Math]::Ceiling($totalBytes / 51200.0)
                    if ($scpTimeoutSeconds -lt 120) { $scpTimeoutSeconds = 120 }
                    if ($scpTimeoutSeconds -gt 600) { $scpTimeoutSeconds = 600 }
                }

                $maxAttempts = 3
                $attempt = 0
                $batchOk = $false
                $stderr = ''
                $runExit = -1
                $runTimedOut = $false

                while ($attempt -lt $maxAttempts -and -not $batchOk) {
                    $attempt++
                    $scpArgList = New-Object System.Collections.Generic.List[string]
                    Add-ScpCommonSshOptions -ArgumentList $scpArgList `
                        -IdentityFile ([string]$Config.ScpIdentityFile) `
                        -Port $port `
                        -KnownHostsFile ([string]$Config.ScpKnownHostsFile) `
                        -ConnectTimeoutSeconds 45 `
                        -VerboseSsh
                    foreach ($f in $batchFiles) {
                        $scpArgList.Add($f)
                    }
                    $scpArgList.Add($remoteTarget)

                    Write-LoggerEvent ("SCP BHistory/daily ({0}): uploading {1} file(s) to {2} (timeout {3}s, attempt {4}/{5}): {6}" -f `
                            $batch.Name, $batchFiles.Count, $remoteTarget, $scpTimeoutSeconds,
                        $attempt, $maxAttempts, ($batchFiles -join '; '))

                    $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-bhist-{0}.out' -f [guid]::NewGuid().ToString('N'))
                    $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-bhist-{0}.err' -f [guid]::NewGuid().ToString('N'))
                    try {
                        $argLine = ConvertTo-ScpArgumentLine -Arguments $scpArgList.ToArray()
                        $run = Invoke-ScpProcessWithTimeout -ScpExe $scpExe -ArgumentList $argLine `
                            -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $scpTimeoutSeconds
                        $stderr = ''
                        if (Test-Path -LiteralPath $errFile) {
                            $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
                        }
                        $runTimedOut = [bool]$run.TimedOut
                        $runExit = -1
                        if ($null -ne $run.ExitCode) { $runExit = [int]$run.ExitCode }

                        if ($runTimedOut) {
                            break
                        }
                        if (-not (Test-ScpCopyFailed -ExitCode $runExit -StdErr "$stderr" -TimedOut $false)) {
                            $batchOk = $true
                            break
                        }
                        if ((Test-ScpConnectFailure -StdErr "$stderr") -and $attempt -lt $maxAttempts) {
                            $null = Invoke-ScpOutboundAllowReconcile -Config $Config -Force
                            Write-LoggerEvent -Level WARN -Message (
                                "SCP BHistory/daily ({0}) connect failed (attempt {1}); retrying in 5s." -f `
                                    $batch.Name, $attempt)
                            Start-Sleep -Seconds 5
                            continue
                        }
                        break
                    }
                    finally {
                        Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
                    }
                }

                if ($batchOk) {
                    Clear-ScpConnectBackoff
                    if ($batch.Name -eq 'BHistory' -and $includeBHistory) {
                        $script:LastBHistoryScpSucceeded = $true
                        $nowUtc = [datetime]::UtcNow
                        foreach ($bf in $batchFiles) {
                            $leaf = Split-Path -Leaf $bf
                            $script:LastBHistoryStateByLeaf[$leaf] = [pscustomobject]@{
                                WriteUtc  = $nowUtc
                                Succeeded = $true
                            }
                            if ($leaf -like 'log-history-op-*.csv') {
                                $script:LastBHistorySourceWriteUtc = $nowUtc
                            }
                        }
                    }
                    Write-LoggerEvent ("SCP BHistory/daily ({0}) succeeded ({1} file(s)) -> {2}: {3}" -f `
                            $batch.Name, $batchFiles.Count, $remoteTarget, ($batchFiles -join '; '))
                    continue
                }

                if ($batch.Name -eq 'BHistory') {
                    $script:LastBHistoryScpSucceeded = $false
                    foreach ($bf in $batchFiles) {
                        $leaf = Split-Path -Leaf $bf
                        $script:LastBHistoryStateByLeaf[$leaf] = [pscustomobject]@{
                            WriteUtc  = $null
                            Succeeded = $false
                        }
                    }
                }

                $reportedExit = $runExit
                $verboseExit = Get-ScpVerboseExitStatus -StdErr "$stderr"
                if ($null -ne $verboseExit) { $reportedExit = $verboseExit }
                if ($runTimedOut) {
                    $msg = ("SCP BHistory/daily ({0}) timed out after {1}s. files={2}; stderr={3}" -f `
                            $batch.Name, $scpTimeoutSeconds, ($batchFiles -join '; '), ("$stderr").Trim())
                }
                else {
                    $msg = ("SCP BHistory/daily ({0}) failed (exit {1}). files={2}; stderr={3}" -f `
                            $batch.Name, $reportedExit, ($batchFiles -join '; '), ("$stderr").Trim())
                }

                $isConnectFail = Test-ScpConnectFailure -StdErr "$stderr"
                if ($isConnectFail) {
                    Set-ScpConnectBackoff
                    if (Write-ScpConnectFailureThrottled -Message $msg -Level 'WARN') {
                        $diagPath = Join-Path $env:TEMP (
                            'LoginTimeLogger-scp-bhist-fail-{0}.txt' -f [guid]::NewGuid().ToString('N'))
                        try {
                            @(
                                $msg
                                ''
                                '--- scp stderr ---'
                                ("$stderr").Trim()
                            ) | Set-Content -LiteralPath $diagPath -Encoding UTF8
                            $null = Send-LoginTimeLoggerFailureAlert `
                                -Subject 'SCP connect failed' `
                                -Body $msg `
                                -AlertKey 'scp-connect-failed' `
                                -Config $Config `
                                -ExtraAttachment @($diagPath)
                        }
                        finally {
                            Remove-Item -LiteralPath $diagPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                    # Do not burn another 3x ConnectTimeout on the next batch this cycle.
                    break
                }
                else {
                    Write-LoggerEvent -Level WARN -Message $msg
                    $diagPath = Join-Path $env:TEMP (
                        'LoginTimeLogger-scp-bhist-fail-{0}.txt' -f [guid]::NewGuid().ToString('N'))
                    try {
                        @(
                            $msg
                            ''
                            '--- scp stderr ---'
                            ("$stderr").Trim()
                        ) | Set-Content -LiteralPath $diagPath -Encoding UTF8
                        $null = Send-LoginTimeLoggerFailureAlert `
                            -Subject 'SCP BHistory/daily failed' `
                            -Body $msg `
                            -AlertKey ('scp-bhist-daily-failed-{0}' -f $batch.Name) `
                            -Config $Config `
                            -ExtraAttachment @($diagPath)
                    }
                    finally {
                        Remove-Item -LiteralPath $diagPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
        }

        # commands.txt exchange is scheduled separately every 1 minute.
    }
    catch {
        if ($includeBHistory) {
            $script:LastBHistoryScpSucceeded = $false
        }
        $details = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'ScpBHistory' -Context (
            'SCP BHistory/daily failed')
        $null = Send-LoginTimeLoggerFailureAlert `
            -Subject 'SCP BHistory/daily failed' `
            -Body ([string]$details) `
            -AlertKey 'scp-bhist-daily-failed' `
            -Config $Config
    }
}
