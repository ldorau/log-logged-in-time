# SCP helper for LoginTimeLogger (dot-sourced by the monitor).
# On screen lock, copies today's unlocked-time log and errors.log to a remote host.

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

function Test-ScpOnLockConfigured {
    param([Parameter(Mandatory)]$Config)

    if (-not $Config.ScpOnLockEnabled) {
        return $false
    }
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

function Invoke-ScpLogCopyOnLock {
    <#
    .SYNOPSIS
      Copies the daily time log and error log to the configured remote via scp.
      Failures are logged; they do not stop the monitor.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$TimeLogPath,
        [Parameter(Mandatory)][string]$ErrorLogPath
    )

    if (-not (Test-ScpOnLockConfigured -Config $Config)) {
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

        $files = New-Object System.Collections.Generic.List[string]
        if (Test-Path -LiteralPath $TimeLogPath) {
            $files.Add($TimeLogPath)
        }
        else {
            Write-LoggerEvent -Level WARN -Message ("SCP on lock: time log not found yet: {0}" -f $TimeLogPath)
        }
        if (Test-Path -LiteralPath $ErrorLogPath) {
            $files.Add($ErrorLogPath)
        }
        else {
            Write-LoggerEvent -Level WARN -Message ("SCP on lock: error log not found yet: {0}" -f $ErrorLogPath)
        }
        if ($files.Count -eq 0) {
            Write-LoggerEvent -Level WARN -Message 'SCP on lock skipped: neither time log nor error log exists.'
            return
        }

        $remoteDir = [string]$Config.ScpRemoteDirectory
        if (-not $remoteDir.EndsWith('/')) {
            $remoteDir = $remoteDir + '/'
        }
        $remoteTarget = '{0}@{1}:{2}' -f $Config.ScpUser, $Config.ScpHost, $remoteDir

        $port = 22
        if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
            $port = [int]$Config.ScpPort
        }

        $args = New-Object System.Collections.Generic.List[string]
        $args.Add('-i')
        $args.Add($Config.ScpIdentityFile)
        $args.Add('-P')
        $args.Add("$port")
        $args.Add('-o')
        $args.Add('BatchMode=yes')
        $args.Add('-o')
        $args.Add('StrictHostKeyChecking=accept-new')
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.ScpKnownHostsFile)) {
            $args.Add('-o')
            $args.Add(('UserKnownHostsFile={0}' -f $Config.ScpKnownHostsFile))
        }
        $args.Add('-o')
        $args.Add('ConnectTimeout=15')
        foreach ($f in $files) {
            $args.Add($f)
        }
        $args.Add($remoteTarget)

        Write-LoggerEvent ("SCP on lock: copying {0} file(s) to {1}" -f $files.Count, $remoteTarget)

        $outFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.out' -f [guid]::NewGuid().ToString('N'))
        $errFile = Join-Path $env:TEMP ('LoginTimeLogger-scp-{0}.err' -f [guid]::NewGuid().ToString('N'))
        try {
            $proc = Start-Process -FilePath $scpExe -ArgumentList $args.ToArray() `
                -Wait -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $outFile -RedirectStandardError $errFile
            $stdout = ''
            $stderr = ''
            if (Test-Path -LiteralPath $outFile) {
                $stdout = (Get-Content -LiteralPath $outFile -Raw -ErrorAction SilentlyContinue)
            }
            if (Test-Path -LiteralPath $errFile) {
                $stderr = (Get-Content -LiteralPath $errFile -Raw -ErrorAction SilentlyContinue)
            }
            if ($proc.ExitCode -ne 0) {
                Write-LoggerEvent -Level ERROR -Message ("SCP on lock failed (exit {0}). stderr={1} stdout={2}" -f `
                        $proc.ExitCode, ("$stderr").Trim(), ("$stdout").Trim())
                return
            }
            Write-LoggerEvent ("SCP on lock succeeded: {0}" -f ($files -join ', '))
        }
        finally {
            Remove-Item -LiteralPath $outFile, $errFile -Force -ErrorAction SilentlyContinue
        }
    }
    catch {
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'ScpOnLock' -Context 'SCP on lock failed'
    }
}
