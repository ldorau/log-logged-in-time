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

function Protect-ScpPrivateKeyFile {
    <#
      OpenSSH refuses private keys that any non-caller account can read.
      The monitor runs scp as SYSTEM, so the key must be SYSTEM-only
      (admin+Users ACEs cause "UNPROTECTED PRIVATE KEY FILE").
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
      Collects log files for SCP-on-lock: today's time log, errors.log, and every
      *.log / *.csv / state.json under LogDirectory (deduped).
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

    & $addFile $TimeLogPath
    & $addFile $ErrorLogPath

    $logDir = ''
    if ($Config -and -not [string]::IsNullOrWhiteSpace([string]$Config.LogDirectory)) {
        $logDir = [string]$Config.LogDirectory
    }
    if (-not [string]::IsNullOrWhiteSpace($logDir) -and (Test-Path -LiteralPath $logDir)) {
        Get-ChildItem -LiteralPath $logDir -File -Force -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -eq 'state.json' -or
                $_.Extension -eq '.log' -or
                $_.Extension -eq '.csv'
            } |
            ForEach-Object { & $addFile $_.FullName }
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
      Includes today's time log, errors.log, service.log, summary CSV, state.json,
      and any other *.log/*.csv under LogDirectory. Failures are logged; they do
      not stop the monitor. Failed copies also email with error logs attached when SMTP is enabled.
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
        $scpArgList.Add('-i')
        $scpArgList.Add(([string]$Config.ScpIdentityFile).Trim())
        $scpArgList.Add('-P')
        $scpArgList.Add("$port")
        $scpArgList.Add('-o')
        $scpArgList.Add('BatchMode=yes')
        $scpArgList.Add('-o')
        $scpArgList.Add('IdentitiesOnly=yes')
        $scpArgList.Add('-o')
        $scpArgList.Add('PreferredAuthentications=publickey')
        $scpArgList.Add('-o')
        $scpArgList.Add('StrictHostKeyChecking=accept-new')
        if (-not [string]::IsNullOrWhiteSpace([string]$Config.ScpKnownHostsFile)) {
            $scpArgList.Add('-o')
            $scpArgList.Add(('UserKnownHostsFile={0}' -f ([string]$Config.ScpKnownHostsFile).Trim()))
        }
        $scpArgList.Add('-o')
        $scpArgList.Add('ConnectTimeout=20')
        foreach ($f in $files) {
            $scpArgList.Add($f)
        }
        $scpArgList.Add($remoteTarget)

        Write-LoggerEvent ("SCP on lock: copying {0} file(s) to {1}: {2}" -f `
                $files.Count, $remoteTarget, ($files -join '; '))

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

            $proc = Start-Process -FilePath $scpExe -ArgumentList $argLine `
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
            $exitCode = -1
            if ($null -ne $proc) {
                $exitCode = [int]$proc.ExitCode
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
