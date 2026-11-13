# SCP helper for LoginTimeLogger (dot-sourced by the monitor).
# On screen lock, copies the two newest unlocked-time-*.log files and error logs.

# BHistory periodic SCP (not configurable).
$script:ScpBHistoryIntervalMinutes = 5
# StrictMode-safe defaults (Test-ScpOnLock / Copy-LogsViaScp dot-source this file).
$script:LastBHistoryMissingWarnUtc = $null
$script:LastBHistorySourceWriteUtc = $null
$script:LastBHistoryScpSucceeded = $false
# Per staged leaf (log-history-op / log-history-ch): WriteUtc + Succeeded.
$script:LastBHistoryStateByLeaf = @{}

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
# Relative History paths under AppData\Roaming (order matches discovery preference).
$script:ScpBHistoryRoamingRels = @(
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXERlZmF1bHRcSGlzdG9yeQ==')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgR1ggU3RhYmxlXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'T3BlcmEgU29mdHdhcmVcT3BlcmEgR1hcSGlzdG9yeQ==')
)
# Relative History paths under AppData\Local (includes Programs\... installs).
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
# Relative History paths under AppData\Local for the second browser family.
$script:ScpBHistorySecondaryLocalRels = @(
    (ConvertFrom-ScpB64Path 'R29vZ2xlXENocm9tZVxVc2VyIERhdGFcRGVmYXVsdFxIaXN0b3J5')
    (ConvertFrom-ScpB64Path 'R29vZ2xlXENocm9tZVxVc2VyIERhdGFcUHJvZmlsZSAxXEhpc3Rvcnk=')
    (ConvertFrom-ScpB64Path 'R29vZ2xlXENocm9tZVxVc2VyIERhdGFcSGlzdG9yeQ==')
)
# History paths relative to a browser install directory.
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
        ($StdErr -match '(?i)No more authentication methods to try')
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
    $ArgumentList.Add('ConnectTimeout=20')
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
      Starts scp and waits up to TimeoutSeconds. On timeout, kills the process
      tree and returns TimedOut=$true with ExitCode=-1.
      ConnectTimeout alone is not enough: a stalled transfer can block for hours.
    #>
    param(
        [Parameter(Mandatory)][string]$ScpExe,
        [Parameter(Mandatory)][string]$ArgumentList,
        [Parameter(Mandatory)][string]$StdOutPath,
        [Parameter(Mandatory)][string]$StdErrPath,
        [ValidateRange(5, 3600)]
        [int]$TimeoutSeconds = 90
    )

    $proc = Start-Process -FilePath $ScpExe -ArgumentList $ArgumentList `
        -PassThru -WindowStyle Hidden `
        -RedirectStandardOutput $StdOutPath -RedirectStandardError $StdErrPath

    if ($null -eq $proc) {
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $false
            Process  = $null
        }
    }

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
        return [pscustomobject]@{
            ExitCode = -1
            TimedOut = $true
            Process  = $proc
        }
    }

    $code = -1
    try {
        if ($proc.HasExited) {
            $code = [int]$proc.ExitCode
        }
    }
    catch {
        $code = -1
    }

    return [pscustomobject]@{
        ExitCode = $code
        TimedOut = $false
        Process  = $proc
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
      Candidate browser install directories (Program Files, Local\Programs, Uninstall registry).
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
            $display = [string]$_.DisplayName
            $install = [string]$_.InstallLocation
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

    return ,$roots.ToArray()
}

function Resolve-BHistoryPathForFamily {
    <#
      First existing History path for one browser family.
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

function Get-BHistorySources {
    <#
      All discoverable History DBs for the target user (one per family).
      Returns objects: Path, StageLeaf (remote/temp file name).
    #>
    param(
        [Parameter(Mandatory)][string]$TargetUsername
    )

    $sources = New-Object System.Collections.Generic.List[object]

    $primary = Resolve-BHistoryPathForFamily `
        -TargetUsername $TargetUsername `
        -PreferredAbsolute ([string]$script:ScpBHistoryPreferredAbsolute) `
        -RoamingRels @($script:ScpBHistoryRoamingRels) `
        -LocalRels @($script:ScpBHistoryLocalRels) `
        -InstallDirLeaves @($script:ScpBHistoryInstallDirLeaves)
    if (-not [string]::IsNullOrWhiteSpace($primary)) {
        $sources.Add([pscustomobject]@{
                Path      = $primary
                StageLeaf = 'log-history-op'
            })
    }

    $secondary = Resolve-BHistoryPathForFamily `
        -TargetUsername $TargetUsername `
        -PreferredAbsolute ([string]$script:ScpBHistoryPreferredAbsoluteSecondary) `
        -RoamingRels @() `
        -LocalRels @($script:ScpBHistorySecondaryLocalRels) `
        -InstallDirLeaves @($script:ScpBHistorySecondaryInstallDirLeaves)
    if (-not [string]::IsNullOrWhiteSpace($secondary)) {
        $sources.Add([pscustomobject]@{
                Path      = $secondary
                StageLeaf = 'log-history-ch'
            })
    }

    return ,$sources.ToArray()
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
      (log-history-op, log-history-ch, ...). Returns staged full paths.
      Caller must delete returned paths when finished.
    #>
    param([Parameter(Mandatory)][string]$TargetUsername)

    $staged = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($TargetUsername)) {
        return ,$staged.ToArray()
    }

    foreach ($src in @(Get-BHistorySources -TargetUsername $TargetUsername)) {
        $sourcePath = [string]$src.Path
        $leaf = [string]$src.StageLeaf
        if ([string]::IsNullOrWhiteSpace($sourcePath) -or [string]::IsNullOrWhiteSpace($leaf)) {
            continue
        }
        if (-not (Test-Path -LiteralPath $sourcePath)) {
            continue
        }
        $stagedPath = Join-Path $env:TEMP $leaf
        if (Test-Path -LiteralPath $stagedPath) {
            Remove-Item -LiteralPath $stagedPath -Force -ErrorAction SilentlyContinue
        }
        if (Copy-FileWithSharedRead -SourcePath $sourcePath -DestinationPath $stagedPath) {
            $staged.Add($stagedPath)
        }
    }
    return ,$staged.ToArray()
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
      files under LogDirectory, plus all error logs (errors.log paths).
      Does not copy service.log, summary CSV, state.json, or older time logs.
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
    }

    return @($files)
}

function Get-ScpManualSourceFiles {
    <#
      Collects a fuller set for manual SCP: every unlocked-time-*.log under
      LogDirectory, all error logs, unlocked-time-summary.csv, and state.json.
      Does not include service.log.
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

    if (-not [string]::IsNullOrWhiteSpace($logDir) -and (Test-Path -LiteralPath $logDir)) {
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'unlocked-time-*.log' -ErrorAction SilentlyContinue |
            Sort-Object Name |
            ForEach-Object { & $addFile $_.FullName }

        & $addFile (Join-Path $logDir 'unlocked-time-summary.csv')
        & $addFile (Join-Path $logDir 'state.json')

        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter 'errors.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }
        Get-ChildItem -LiteralPath $logDir -File -Force `
            -Filter '*error*.log' -ErrorAction SilentlyContinue |
            ForEach-Object { & $addFile $_.FullName }
    }

    & $addFile $ErrorLogPath
    if (Get-Command Get-ErrorLogPath -ErrorAction SilentlyContinue) {
        try { & $addFile (Get-ErrorLogPath) } catch { }
    }

    return @($files)
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
            -Subject 'SCP on lock failed' `
            -Body $Body `
            -AlertKey 'scp-on-lock-failed' `
            -Attachment @($attachments))
}

function Invoke-ScpLogCopyOnLock {
    <#
    .SYNOPSIS
      Copies LoginTimeLogger logs to the configured remote via scp on screen lock.
      Copies the two newest unlocked-time-*.log files and all error logs.
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

        # Do not name this $args (PowerShell automatic variable).
        $scpArgList = New-Object System.Collections.Generic.List[string]
        Add-ScpCommonSshOptions -ArgumentList $scpArgList `
            -IdentityFile ([string]$Config.ScpIdentityFile) `
            -Port $port `
            -KnownHostsFile ([string]$Config.ScpKnownHostsFile)
        foreach ($f in $files) {
            $scpArgList.Add($f)
        }
        $scpArgList.Add($remoteTarget)

        # Hard cap: ConnectTimeout only covers TCP connect. A stalled transfer
        # previously blocked the monitor for hours (see Connection aborted after ~2.5h).
        $scpTimeoutSeconds = 90

        Write-LoggerEvent ("SCP on lock: copying {0} file(s) to {1} (timeout {2}s): {3}" -f `
                $files.Count, $remoteTarget, $scpTimeoutSeconds, ($files -join '; '))

        $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.out' -f [guid]::NewGuid().ToString('N'))
        $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.err' -f [guid]::NewGuid().ToString('N'))
        try {
            $argLine = $null
            if (Get-Command ConvertTo-StartProcessArgumentString -ErrorAction SilentlyContinue) {
                $argLine = ConvertTo-StartProcessArgumentString -Argument $scpArgList.ToArray()
            }
            if ([string]::IsNullOrWhiteSpace($argLine)) {
                # Fallback: still better than $args automatic-variable confusion.
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
            $exitCode = [int]$run.ExitCode
            if ($run.TimedOut) {
                $msg = ("SCP on lock timed out after {0}s (killed). target={1}; files={2}; stderr={3}; stdout={4}" -f `
                        $scpTimeoutSeconds, $remoteTarget, ($files -join '; '), ("$stderr").Trim(), ("$stdout").Trim())
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
                return
            }
            if ($exitCode -ne 0) {
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
                # WARN: still records to errors.log / service.log, but avoids a second attachment-less SMTP from ERROR.
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
                return
            }
            Write-LoggerEvent ("SCP on lock succeeded ({0} file(s)): {1}" -f $files.Count, ($files -join '; '))
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
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

function Invoke-ScpBHistoryCopy {
    <#
    .SYNOPSIS
      Every interval: SCPs BHistory (when present/changed) and today's
      unlocked-time-*.log to ScpRemoteDirectory. BHistory uses a shared-read
      temp copy so a locked SQLite DB can still be uploaded.
      Failures are logged; they do not stop the monitor.
    #>
    param(
        [Parameter(Mandatory)]$Config
    )

    if (-not (Test-ScpEndpointConfigured -Config $Config)) {
        return
    }

    $tempCopies = New-Object System.Collections.Generic.List[string]
    $uploadFiles = New-Object System.Collections.Generic.List[string]
    $stagedSourceByLeaf = @{}
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
        else {
            $needStage = $false
            foreach ($src in $sources) {
                $leaf = [string]$src.StageLeaf
                $sourcePath = [string]$src.Path
                $sourceItem = Get-Item -LiteralPath $sourcePath -Force
                $writeUtc = $sourceItem.LastWriteTimeUtc
                $stagedSourceByLeaf[$leaf] = [pscustomobject]@{
                    Path     = $sourcePath
                    WriteUtc = $writeUtc
                }
                $prev = $null
                if ($script:LastBHistoryStateByLeaf.ContainsKey($leaf)) {
                    $prev = $script:LastBHistoryStateByLeaf[$leaf]
                }
                $unchanged = (
                    $null -ne $prev -and
                    $prev.WriteUtc -is [datetime] -and
                    $writeUtc -le $prev.WriteUtc -and
                    [bool]$prev.Succeeded)
                if (-not $unchanged) {
                    $needStage = $true
                }
            }
            if ($needStage) {
                $staged = @(New-ScpBHistoryUploadFiles -TargetUsername ([string]$Config.TargetUsername))
                if ($staged.Count -eq 0) {
                    Write-LoggerEvent -Level WARN -Message 'SCP BHistory: could not stage any History file.'
                }
                else {
                    foreach ($s in $staged) {
                        $tempCopies.Add($s)
                        $uploadFiles.Add($s)
                    }
                    $includeBHistory = $true
                }
            }
        }

        $dailyPath = Get-CurrentUnlockedTimeLogPath -Config $Config
        if (-not [string]::IsNullOrWhiteSpace($dailyPath) -and (Test-Path -LiteralPath $dailyPath)) {
            $uploadFiles.Add($dailyPath)
        }

        if ($uploadFiles.Count -eq 0) {
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

        # Upload daily log first (small/fast), then BHistory separately so a
        # large History timeout cannot block the day-log copy.
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
            @{ Name = 'daily'; Files = @($dailyFiles); TimeoutSeconds = 60 }
            @{ Name = 'BHistory'; Files = @($historyFiles); TimeoutSeconds = 0 }
        )

        foreach ($batch in $uploadBatches) {
            $batchFiles = @($batch.Files)
            if ($batchFiles.Count -eq 0) {
                continue
            }

            $scpTimeoutSeconds = [int]$batch.TimeoutSeconds
            if ($scpTimeoutSeconds -le 0) {
                # Scale with payload size (~50 KiB/s floor + 60s slack), clamp 180..600.
                $totalBytes = [int64]0
                foreach ($bf in $batchFiles) {
                    try {
                        $totalBytes += [int64](Get-Item -LiteralPath $bf -Force).Length
                    }
                    catch { }
                }
                $scpTimeoutSeconds = 60 + [int][Math]::Ceiling($totalBytes / 51200.0)
                if ($scpTimeoutSeconds -lt 180) { $scpTimeoutSeconds = 180 }
                if ($scpTimeoutSeconds -gt 600) { $scpTimeoutSeconds = 600 }
            }

            $scpArgList = New-Object System.Collections.Generic.List[string]
            Add-ScpCommonSshOptions -ArgumentList $scpArgList `
                -IdentityFile ([string]$Config.ScpIdentityFile) `
                -Port $port `
                -KnownHostsFile ([string]$Config.ScpKnownHostsFile)
            foreach ($f in $batchFiles) {
                $scpArgList.Add($f)
            }
            $scpArgList.Add($remoteTarget)

            Write-LoggerEvent ("SCP BHistory/daily ({0}): uploading {1} file(s) to {2} (timeout {3}s): {4}" -f `
                    $batch.Name, $batchFiles.Count, $remoteTarget, $scpTimeoutSeconds, ($batchFiles -join '; '))

            $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-bhist-{0}.out' -f [guid]::NewGuid().ToString('N'))
            $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-bhist-{0}.err' -f [guid]::NewGuid().ToString('N'))
            try {
                $argLine = $null
                if (Get-Command ConvertTo-StartProcessArgumentString -ErrorAction SilentlyContinue) {
                    $argLine = ConvertTo-StartProcessArgumentString -Argument $scpArgList.ToArray()
                }
                if ([string]::IsNullOrWhiteSpace($argLine)) {
                    $argLine = ($scpArgList | ForEach-Object {
                            if ($_ -match '[\s"]') { '"{0}"' -f ($_ -replace '"', '\"') } else { $_ }
                        }) -join ' '
                }

                $run = Invoke-ScpProcessWithTimeout -ScpExe $scpExe -ArgumentList $argLine `
                    -StdOutPath $outFile -StdErrPath $errFile -TimeoutSeconds $scpTimeoutSeconds
                $stderr = ''
                if (Test-Path -LiteralPath $errFile) {
                    $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
                }

                if ($run.TimedOut) {
                    Write-LoggerEvent -Level WARN -Message (
                        "SCP BHistory/daily ({0}) timed out after {1}s. files={2}; stderr={3}" -f `
                            $batch.Name, $scpTimeoutSeconds, ($batchFiles -join '; '), ("$stderr").Trim())
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
                    continue
                }
                if ([int]$run.ExitCode -ne 0) {
                    Write-LoggerEvent -Level WARN -Message (
                        "SCP BHistory/daily ({0}) failed (exit {1}). files={2}; stderr={3}" -f `
                            $batch.Name, $run.ExitCode, ($batchFiles -join '; '), ("$stderr").Trim())
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
                    continue
                }

                if ($batch.Name -eq 'BHistory' -and $includeBHistory) {
                    $script:LastBHistoryScpSucceeded = $true
                    foreach ($bf in $batchFiles) {
                        $leaf = Split-Path -Leaf $bf
                        $writeUtc = $null
                        if ($stagedSourceByLeaf.ContainsKey($leaf)) {
                            $writeUtc = $stagedSourceByLeaf[$leaf].WriteUtc
                        }
                        $script:LastBHistoryStateByLeaf[$leaf] = [pscustomobject]@{
                            WriteUtc  = $writeUtc
                            Succeeded = $true
                        }
                        if ($leaf -eq 'log-history-op' -and $writeUtc -is [datetime]) {
                            $script:LastBHistorySourceWriteUtc = $writeUtc
                        }
                    }
                }
                Write-LoggerEvent ("SCP BHistory/daily ({0}) succeeded ({1} file(s)) -> {2}: {3}" -f `
                        $batch.Name, $batchFiles.Count, $remoteTarget, ($batchFiles -join '; '))
            }
            finally {
                Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
            }
        }
    }
    catch {
        if ($includeBHistory) {
            $script:LastBHistoryScpSucceeded = $false
        }
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'ScpBHistory' -Context (
            'SCP BHistory/daily failed')
    }
    finally {
        foreach ($tempCopy in @($tempCopies)) {
            if (-not [string]::IsNullOrWhiteSpace($tempCopy) -and (Test-Path -LiteralPath $tempCopy)) {
                Remove-Item -LiteralPath $tempCopy -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
