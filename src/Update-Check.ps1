# Update helper for LoginTimeLogger (dot-sourced by the monitor).
# Once per day: if online, compare local installed commit to GitHub tip;
# if different, git pull (or clone) and restart via the scheduled task.
# After a successful daily check (up-to-date or just updated), also run
# scripts/Force-DnsToLocalResolver.ps1, scripts/Block-DoH-Firewall.ps1,
# scripts/Block-Vpn-Firewall.ps1, and scripts/Allow-ScpOutboundFirewall.ps1 in
# child processes (DNS force, DoH/DoT, VPN blocks, SCP allow when enabled).
# If offline, postpone the check by 10 minutes.
# Only https://github.com/ldorau/log-logged-in-time(.git) is accepted.

$script:DefaultUpdateTaskName = 'LoginTimeLogger'
$script:AllowedUpdateRepoPaths = @(
    '/ldorau/log-logged-in-time'
    '/ldorau/log-logged-in-time.git'
)

function Get-UpdateStatePath {
    param([Parameter(Mandatory)][string]$AdminAppDirectory)
    Join-Path $AdminAppDirectory 'update-state.json'
}

function Get-InstalledCommitPath {
    param([Parameter(Mandatory)][string]$InstallRoot)
    Join-Path $InstallRoot 'installed-commit.txt'
}

function Test-TrustedUpdateRepoUrl {
    param([Parameter(Mandatory)][string]$RepoUrl)

    if ([string]::IsNullOrWhiteSpace($RepoUrl)) {
        return $false
    }

    try {
        $uri = [Uri]$RepoUrl
    }
    catch {
        return $false
    }

    if (-not $uri.IsAbsoluteUri) {
        return $false
    }
    if ($uri.Scheme -ne 'https') {
        return $false
    }
    if (-not [string]::Equals($uri.Host, 'github.com', [StringComparison]::OrdinalIgnoreCase)) {
        return $false
    }

    $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    return $script:AllowedUpdateRepoPaths -contains $path
}

function Read-UpdateState {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            NextUpdateCheckUtc   = [datetime]::UtcNow.ToString('o')
            LastUpdateCheckUtc   = $null
            LastResult           = 'never'
            LastRemoteCommit     = $null
            LastLocalCommit      = $null
            LastDoHBlockUtc      = $null
            LastDoHBlockResult   = $null
            LastVpnBlockUtc      = $null
            LastVpnBlockResult   = $null
            LastDnsForceUtc      = $null
            LastDnsForceResult   = $null
            LastScpAllowUtc      = $null
            LastScpAllowResult   = $null
        }
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            NextUpdateCheckUtc = $(if ($json.NextUpdateCheckUtc) { [string]$json.NextUpdateCheckUtc } else { [datetime]::UtcNow.ToString('o') })
            LastUpdateCheckUtc = $(if ($json.LastUpdateCheckUtc) { [string]$json.LastUpdateCheckUtc } else { $null })
            LastResult         = $(if ($json.LastResult) { [string]$json.LastResult } else { 'unknown' })
            LastRemoteCommit   = $(if ($json.LastRemoteCommit) { [string]$json.LastRemoteCommit } else { $null })
            LastLocalCommit    = $(if ($json.LastLocalCommit) { [string]$json.LastLocalCommit } else { $null })
            LastDoHBlockUtc    = $(if ($json.LastDoHBlockUtc) { [string]$json.LastDoHBlockUtc } else { $null })
            LastDoHBlockResult = $(if ($json.LastDoHBlockResult) { [string]$json.LastDoHBlockResult } else { $null })
            LastVpnBlockUtc    = $(if ($json.LastVpnBlockUtc) { [string]$json.LastVpnBlockUtc } else { $null })
            LastVpnBlockResult = $(if ($json.LastVpnBlockResult) { [string]$json.LastVpnBlockResult } else { $null })
            LastDnsForceUtc    = $(if ($json.LastDnsForceUtc) { [string]$json.LastDnsForceUtc } else { $null })
            LastDnsForceResult = $(if ($json.LastDnsForceResult) { [string]$json.LastDnsForceResult } else { $null })
            LastScpAllowUtc    = $(if ($json.LastScpAllowUtc) { [string]$json.LastScpAllowUtc } else { $null })
            LastScpAllowResult = $(if ($json.LastScpAllowResult) { [string]$json.LastScpAllowResult } else { $null })
        }
    }
    catch {
        Write-LoggerEvent -Level WARN -Message ("Corrupt update-state.json; resetting. {0}" -f $_.Exception.Message)
        return [pscustomobject]@{
            NextUpdateCheckUtc   = [datetime]::UtcNow.ToString('o')
            LastUpdateCheckUtc   = $null
            LastResult           = 'reset-corrupt'
            LastRemoteCommit     = $null
            LastLocalCommit      = $null
            LastDoHBlockUtc      = $null
            LastDoHBlockResult   = $null
            LastVpnBlockUtc      = $null
            LastVpnBlockResult   = $null
            LastDnsForceUtc      = $null
            LastDnsForceResult   = $null
            LastScpAllowUtc      = $null
            LastScpAllowResult   = $null
        }
    }
}

function Write-UpdateState {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )
    $dir = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $tempPath = "$Path.tmp"
    ($State | ConvertTo-Json -Depth 5) | Set-Content -LiteralPath $tempPath -Encoding UTF8
    Move-Item -LiteralPath $tempPath -Destination $Path -Force
}

function Get-InstalledCommit {
    param([Parameter(Mandatory)][string]$InstallRoot)

    $path = Get-InstalledCommitPath -InstallRoot $InstallRoot
    if (-not (Test-Path -LiteralPath $path)) {
        return $null
    }
    $sha = (Get-Content -LiteralPath $path -TotalCount 1 -ErrorAction SilentlyContinue)
    if ($null -eq $sha) { return $null }
    return $sha.Trim().ToLowerInvariant()
}

function Set-InstalledCommit {
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$CommitSha
    )
    $path = Get-InstalledCommitPath -InstallRoot $InstallRoot
    $tempPath = "$path.tmp"
    Set-Content -LiteralPath $tempPath -Value $CommitSha.Trim().ToLowerInvariant() -Encoding ASCII
    Move-Item -LiteralPath $tempPath -Destination $path -Force
}

function Test-InternetAvailable {
    # Prefer a real HTTPS check to GitHub; fall back to TCP 443.
    try {
        $null = Invoke-WebRequest -Uri 'https://github.com' -UseBasicParsing -Method Head -TimeoutSec 10
        return $true
    }
    catch {
        # continue
    }

    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $async = $tcp.BeginConnect('github.com', 443, $null, $null)
        $ok = $async.AsyncWaitHandle.WaitOne(5000, $false)
        if ($ok -and $tcp.Connected) {
            $tcp.Close()
            return $true
        }
        try { $tcp.Close() } catch { }
        return $false
    }
    catch {
        return $false
    }
}

function Find-GitExecutable {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe')
        (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-GitCommand {
    <#
      Git writes progress to stderr. With $ErrorActionPreference Stop, PowerShell
      turns that into NativeCommandError even when git exits 0. Temporarily use
      Continue and trust LASTEXITCODE.
    #>
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$RepoPath
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if (-not [string]::IsNullOrWhiteSpace($RepoPath)) {
            $output = & $GitExe -C $RepoPath @Arguments 2>&1
        }
        else {
            $output = & $GitExe @Arguments 2>&1
        }
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
        Lines    = @($output | ForEach-Object { "$_" })
    }
}

function Get-RemoteCommitSha {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoUrl,
        [Parameter(Mandatory)][string]$Branch
    )

    $ref = "refs/heads/$Branch"
    $result = Invoke-GitCommand -GitExe $GitExe -Arguments @('ls-remote', '--heads', $RepoUrl, $Branch)
    if ($result.ExitCode -ne 0) {
        throw ("git ls-remote failed (exit {0}): {1}" -f $result.ExitCode, $result.Output)
    }

    foreach ($line in @($result.Lines)) {
        $text = "$line".Trim()
        if ($text -match '^(?<sha>[0-9a-fA-F]{40})\s+(?<ref>\S+)$') {
            if ($Matches['ref'] -eq $ref -or $Matches['ref'] -eq $Branch) {
                return $Matches['sha'].ToLowerInvariant()
            }
        }
    }

    throw ("Could not parse remote commit for refs/heads/{0} from git ls-remote output: {1}" -f $Branch, $result.Output)
}

function Sync-UpdateRepository {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoUrl,
        [Parameter(Mandatory)][string]$Branch,
        [Parameter(Mandatory)][string]$ClonePath
    )

    $parent = Split-Path -Parent $ClonePath
    if (-not (Test-Path -LiteralPath $parent)) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }

    if (-not (Test-Path -LiteralPath (Join-Path $ClonePath '.git'))) {
        Write-LoggerEvent ("Cloning {0} (branch {1}) into {2}" -f $RepoUrl, $Branch, $ClonePath)
        $clone = Invoke-GitCommand -GitExe $GitExe -Arguments @(
            'clone', '--branch', $Branch, '--single-branch', '--depth', '1', $RepoUrl, $ClonePath
        )
        if ($clone.ExitCode -ne 0) {
            throw ("git clone failed (exit {0}): {1}" -f $clone.ExitCode, $clone.Output)
        }
    }
    else {
        Write-LoggerEvent ("git fetch/pull in {0}" -f $ClonePath)
        $fetch = Invoke-GitCommand -GitExe $GitExe -RepoPath $ClonePath -Arguments @('fetch', 'origin', $Branch)
        if ($fetch.ExitCode -ne 0) {
            throw ("git fetch failed (exit {0}): {1}" -f $fetch.ExitCode, $fetch.Output)
        }
        # Unattended-safe equivalent of updating to newest tip after pull/fetch.
        $pull = Invoke-GitCommand -GitExe $GitExe -RepoPath $ClonePath -Arguments @('pull', '--ff-only', 'origin', $Branch)
        if ($pull.ExitCode -ne 0) {
            Write-LoggerEvent -Level WARN -Message ("git pull --ff-only failed; hard-resetting to origin/{0}. Detail: {1}" -f $Branch, $pull.Output)
            $reset = Invoke-GitCommand -GitExe $GitExe -RepoPath $ClonePath -Arguments @('reset', '--hard', ("origin/{0}" -f $Branch))
            if ($reset.ExitCode -ne 0) {
                throw ("git reset --hard failed (exit {0}): {1}" -f $reset.ExitCode, $reset.Output)
            }
        }
    }

    $head = Invoke-GitCommand -GitExe $GitExe -RepoPath $ClonePath -Arguments @('rev-parse', 'HEAD')
    if ($head.ExitCode -ne 0) {
        throw ("git rev-parse HEAD failed: {0}" -f $head.Output)
    }
    return ($head.Output).Trim().ToLowerInvariant()
}

function Publish-InstalledFilesFromRepo {
    param(
        [Parameter(Mandatory)][string]$ClonePath,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $srcDir = Join-Path $ClonePath 'src'
    $destDir = Join-Path $InstallRoot 'src'
    if (-not (Test-Path -LiteralPath $srcDir)) {
        throw "Cloned repo missing src directory: $srcDir"
    }
    if (-not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    $required = @(
        'LoginTimeLogger.ps1'
        'SessionQuery.cs'
        'Common-Error.ps1'
        'Update-Check.ps1'
        'Scp-OnLock.ps1'
        'LockSignalWatcher.ps1'
        'LockSignalLauncher.ps1'
    )
    foreach ($name in $required) {
        $from = Join-Path $srcDir $name
        if (-not (Test-Path -LiteralPath $from)) {
            throw "Required file missing in clone: $from"
        }
        Copy-Item -LiteralPath $from -Destination (Join-Path $destDir $name) -Force
    }

    # Optional SMTP helper (older clones may lack it).
    $smtpHelper = Join-Path $srcDir 'Common-Smtp.ps1'
    if (Test-Path -LiteralPath $smtpHelper) {
        Copy-Item -LiteralPath $smtpHelper -Destination (Join-Path $destDir 'Common-Smtp.ps1') -Force
    }

    # Daily DNS/DoH helpers (optional for older clones; preferred when present).
    $scriptsSrc = Join-Path $ClonePath 'scripts'
    $scriptsDest = Join-Path $InstallRoot 'scripts'
    $helperFiles = @(
        'Block-DoH-Firewall.ps1'
        'Block-DoH-Providers.json'
        'Block-Vpn-Firewall.ps1'
        'Block-Vpn-Providers.json'
        'Force-DnsToLocalResolver.ps1'
        'Allow-ScpOutboundFirewall.ps1'
    )
    foreach ($name in $helperFiles) {
        $from = Join-Path $scriptsSrc $name
        if (-not (Test-Path -LiteralPath $from)) {
            Write-LoggerEvent -Level WARN -Message ("Helper script missing in clone (skipped): {0}" -f $from)
            continue
        }
        if (-not (Test-Path -LiteralPath $scriptsDest)) {
            New-Item -ItemType Directory -Path $scriptsDest -Force | Out-Null
        }
        Copy-Item -LiteralPath $from -Destination (Join-Path $scriptsDest $name) -Force
    }
}

function Invoke-DailyDoHFirewallBlock {
    <#
      Runs Block-DoH-Firewall.ps1 once after a successful daily update check.
      Uses a child powershell.exe so the script's exit codes cannot stop the monitor.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$ClonePath,
        [Parameter(Mandatory)]$UpdateState,
        [Parameter(Mandatory)][string]$StatePath
    )

    $scriptPath = $null
    $providersPath = $null

    $cloneScript = $null
    $cloneProviders = $null
    if (-not [string]::IsNullOrWhiteSpace($ClonePath)) {
        $cloneScript = Join-Path $ClonePath 'scripts\Block-DoH-Firewall.ps1'
        $cloneProviders = Join-Path $ClonePath 'scripts\Block-DoH-Providers.json'
    }
    $installScript = Join-Path $InstallRoot 'scripts\Block-DoH-Firewall.ps1'
    $installProviders = Join-Path $InstallRoot 'scripts\Block-DoH-Providers.json'

    # Prefer the just-synced clone, then the published Program Files copy.
    if ($cloneScript -and (Test-Path -LiteralPath $cloneScript)) {
        $scriptPath = $cloneScript
        if ($cloneProviders -and (Test-Path -LiteralPath $cloneProviders)) {
            $providersPath = $cloneProviders
        }
    }
    elseif (Test-Path -LiteralPath $installScript) {
        $scriptPath = $installScript
        if (Test-Path -LiteralPath $installProviders) {
            $providersPath = $installProviders
        }
    }
    else {
        $UpdateState.LastDoHBlockUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastDoHBlockResult = 'skipped-script-missing'
        Write-UpdateState -Path $StatePath -State $UpdateState
        Write-LoggerEvent -Level WARN -Message (
            'Daily DoH/DoT firewall reconcile skipped: Block-DoH-Firewall.ps1 not found in clone or InstallRoot\scripts.')
        return
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-NonInteractive')
    $argList.Add('-WindowStyle')
    $argList.Add('Hidden')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($scriptPath)
    if (-not [string]::IsNullOrWhiteSpace($providersPath)) {
        $argList.Add('-ProvidersPath')
        $argList.Add($providersPath)
    }

    Write-LoggerEvent ("Daily DoH/DoT firewall reconcile starting: {0}" -f $scriptPath)
    try {
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argList.ToArray() `
            -Wait -PassThru -WindowStyle Hidden
        $exitCode = 0
        if ($null -ne $proc) {
            $exitCode = [int]$proc.ExitCode
        }
        $UpdateState.LastDoHBlockUtc = [datetime]::UtcNow.ToString('o')
        if ($exitCode -eq 0) {
            $UpdateState.LastDoHBlockResult = 'ok'
            Write-LoggerEvent 'Daily DoH/DoT firewall reconcile finished successfully.'
        }
        else {
            $UpdateState.LastDoHBlockResult = ('exit-{0}' -f $exitCode)
            Write-LoggerEvent -Level WARN -Message (
                "Daily DoH/DoT firewall reconcile exited with code {0}." -f $exitCode)
        }
        Write-UpdateState -Path $StatePath -State $UpdateState
    }
    catch {
        $UpdateState.LastDoHBlockUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastDoHBlockResult = 'error'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context (
            'Daily DoH/DoT firewall reconcile failed')
    }
}

function Invoke-DailyScpOutboundAllow {
    <#
      Runs Allow-ScpOutboundFirewall.ps1 once after a successful daily update check
      when SCP-on-lock is enabled and ScpHost is set.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$ClonePath,
        [Parameter(Mandatory)]$UpdateState,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Config
    )

    if (-not $Config.ScpOnLockEnabled) {
        $UpdateState.LastScpAllowUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastScpAllowResult = 'skipped-scp-disabled'
        Write-UpdateState -Path $StatePath -State $UpdateState
        return
    }
    if ([string]::IsNullOrWhiteSpace([string]$Config.ScpHost)) {
        $UpdateState.LastScpAllowUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastScpAllowResult = 'skipped-scp-host-empty'
        Write-UpdateState -Path $StatePath -State $UpdateState
        Write-LoggerEvent -Level WARN -Message 'Daily SCP-Allow firewall reconcile skipped: ScpHost is empty.'
        return
    }

    $port = 22
    if ($null -ne $Config.ScpPort -and [int]$Config.ScpPort -gt 0) {
        $port = [int]$Config.ScpPort
    }

    $scriptPath = $null
    $cloneScript = $null
    if (-not [string]::IsNullOrWhiteSpace($ClonePath)) {
        $cloneScript = Join-Path $ClonePath 'scripts\Allow-ScpOutboundFirewall.ps1'
    }
    $installScript = Join-Path $InstallRoot 'scripts\Allow-ScpOutboundFirewall.ps1'

    if ($cloneScript -and (Test-Path -LiteralPath $cloneScript)) {
        $scriptPath = $cloneScript
    }
    elseif (Test-Path -LiteralPath $installScript) {
        $scriptPath = $installScript
    }
    else {
        $UpdateState.LastScpAllowUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastScpAllowResult = 'skipped-script-missing'
        Write-UpdateState -Path $StatePath -State $UpdateState
        Write-LoggerEvent -Level WARN -Message (
            'Daily SCP-Allow firewall reconcile skipped: Allow-ScpOutboundFirewall.ps1 not found in clone or InstallRoot\scripts.')
        return
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-NonInteractive')
    $argList.Add('-WindowStyle')
    $argList.Add('Hidden')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($scriptPath)
    $argList.Add('-RemoteHost')
    $argList.Add([string]$Config.ScpHost)
    $argList.Add('-RemotePort')
    $argList.Add("$port")

    Write-LoggerEvent ("Daily SCP-Allow firewall reconcile starting: {0} ({1}:{2})" -f $scriptPath, $Config.ScpHost, $port)
    try {
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argList.ToArray() `
            -Wait -PassThru -WindowStyle Hidden
        $exitCode = 0
        if ($null -ne $proc) {
            $exitCode = [int]$proc.ExitCode
        }
        $UpdateState.LastScpAllowUtc = [datetime]::UtcNow.ToString('o')
        if ($exitCode -eq 0) {
            $UpdateState.LastScpAllowResult = 'ok'
            Write-LoggerEvent 'Daily SCP-Allow firewall reconcile finished successfully.'
        }
        else {
            $UpdateState.LastScpAllowResult = ('exit-{0}' -f $exitCode)
            Write-LoggerEvent -Level WARN -Message (
                "Daily SCP-Allow firewall reconcile exited with code {0}." -f $exitCode)
        }
        Write-UpdateState -Path $StatePath -State $UpdateState
    }
    catch {
        $UpdateState.LastScpAllowUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastScpAllowResult = 'error'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context (
            'Daily SCP-Allow firewall reconcile failed')
    }
}

function Invoke-DailyVpnFirewallBlock {
    <#
      Runs Block-Vpn-Firewall.ps1 once after a successful daily update check.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$ClonePath,
        [Parameter(Mandatory)]$UpdateState,
        [Parameter(Mandatory)][string]$StatePath
    )

    $scriptPath = $null
    $providersPath = $null

    $cloneScript = $null
    $cloneProviders = $null
    if (-not [string]::IsNullOrWhiteSpace($ClonePath)) {
        $cloneScript = Join-Path $ClonePath 'scripts\Block-Vpn-Firewall.ps1'
        $cloneProviders = Join-Path $ClonePath 'scripts\Block-Vpn-Providers.json'
    }
    $installScript = Join-Path $InstallRoot 'scripts\Block-Vpn-Firewall.ps1'
    $installProviders = Join-Path $InstallRoot 'scripts\Block-Vpn-Providers.json'

    if ($cloneScript -and (Test-Path -LiteralPath $cloneScript)) {
        $scriptPath = $cloneScript
        if ($cloneProviders -and (Test-Path -LiteralPath $cloneProviders)) {
            $providersPath = $cloneProviders
        }
    }
    elseif (Test-Path -LiteralPath $installScript) {
        $scriptPath = $installScript
        if (Test-Path -LiteralPath $installProviders) {
            $providersPath = $installProviders
        }
    }
    else {
        $UpdateState.LastVpnBlockUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastVpnBlockResult = 'skipped-script-missing'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $skipMsg = 'Daily VPN firewall reconcile skipped: Block-Vpn-Firewall.ps1 not found in clone or InstallRoot\scripts.'
        Write-LoggerEvent -Level WARN -Message $skipMsg
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'VPN-block skipped' -Body $skipMsg -AlertKey 'vpn-block-skip-script'
        }
        return
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-NonInteractive')
    $argList.Add('-WindowStyle')
    $argList.Add('Hidden')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($scriptPath)
    if (-not [string]::IsNullOrWhiteSpace($providersPath)) {
        $argList.Add('-ProvidersPath')
        $argList.Add($providersPath)
    }

    Write-LoggerEvent ("Daily VPN firewall reconcile starting: {0}" -f $scriptPath)
    try {
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argList.ToArray() `
            -Wait -PassThru -WindowStyle Hidden
        $exitCode = 0
        if ($null -ne $proc) {
            $exitCode = [int]$proc.ExitCode
        }
        $UpdateState.LastVpnBlockUtc = [datetime]::UtcNow.ToString('o')
        if ($exitCode -eq 0) {
            $UpdateState.LastVpnBlockResult = 'ok'
            Write-LoggerEvent 'Daily VPN firewall reconcile finished successfully.'
        }
        else {
            $UpdateState.LastVpnBlockResult = ('exit-{0}' -f $exitCode)
            $failMsg = ("Daily VPN firewall reconcile exited with code {0}." -f $exitCode)
            Write-LoggerEvent -Level WARN -Message $failMsg
            if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
                $null = Send-LoginTimeSmtpAlert -Subject 'VPN-block failed' -Body $failMsg -AlertKey 'vpn-block-exit'
            }
        }
        Write-UpdateState -Path $StatePath -State $UpdateState
    }
    catch {
        $UpdateState.LastVpnBlockUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastVpnBlockResult = 'error'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $details = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context (
            'Daily VPN firewall reconcile failed')
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'VPN-block failed' -Body $details -AlertKey 'vpn-block-error'
        }
    }
}

function Invoke-DailyDnsForceLocalResolver {
    <#
      Runs Force-DnsToLocalResolver.ps1 once after a successful daily update check.
      Uses a child powershell.exe so exit codes cannot stop the monitor.
      Requires Config.ServerDNS (IPv4); skips when empty.
    #>
    param(
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$ClonePath,
        [Parameter(Mandatory)]$UpdateState,
        [Parameter(Mandatory)][string]$StatePath,
        [Parameter(Mandatory)]$Config
    )

    $dnsServer = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.ServerDNS)) {
        $dnsServer = [string]$Config.ServerDNS.Trim()
    }
    if ([string]::IsNullOrWhiteSpace($dnsServer)) {
        $UpdateState.LastDnsForceUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastDnsForceResult = 'skipped-serverdns-empty'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $skipMsg = 'Daily DNS-force reconcile skipped: ServerDNS is empty in config.'
        Write-LoggerEvent -Level WARN -Message $skipMsg
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'DNS-force skipped' -Body $skipMsg -AlertKey 'dns-force-skip-serverdns'
        }
        return
    }

    $scriptPath = $null
    $cloneScript = $null
    if (-not [string]::IsNullOrWhiteSpace($ClonePath)) {
        $cloneScript = Join-Path $ClonePath 'scripts\Force-DnsToLocalResolver.ps1'
    }
    $installScript = Join-Path $InstallRoot 'scripts\Force-DnsToLocalResolver.ps1'

    if ($cloneScript -and (Test-Path -LiteralPath $cloneScript)) {
        $scriptPath = $cloneScript
    }
    elseif (Test-Path -LiteralPath $installScript) {
        $scriptPath = $installScript
    }
    else {
        $UpdateState.LastDnsForceUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastDnsForceResult = 'skipped-script-missing'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $skipMsg = 'Daily DNS-force reconcile skipped: Force-DnsToLocalResolver.ps1 not found in clone or InstallRoot\scripts.'
        Write-LoggerEvent -Level WARN -Message $skipMsg
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'DNS-force skipped' -Body $skipMsg -AlertKey 'dns-force-skip-script'
        }
        return
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argList = New-Object System.Collections.Generic.List[string]
    $argList.Add('-NoProfile')
    $argList.Add('-NonInteractive')
    $argList.Add('-WindowStyle')
    $argList.Add('Hidden')
    $argList.Add('-ExecutionPolicy')
    $argList.Add('Bypass')
    $argList.Add('-File')
    $argList.Add($scriptPath)
    $argList.Add('-DnsServer')
    $argList.Add($dnsServer)

    Write-LoggerEvent ("Daily DNS-force reconcile starting: {0} (DnsServer={1})" -f $scriptPath, $dnsServer)
    try {
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argList.ToArray() `
            -Wait -PassThru -WindowStyle Hidden
        $exitCode = 0
        if ($null -ne $proc) {
            $exitCode = [int]$proc.ExitCode
        }
        $UpdateState.LastDnsForceUtc = [datetime]::UtcNow.ToString('o')
        if ($exitCode -eq 0) {
            $UpdateState.LastDnsForceResult = 'ok'
            Write-LoggerEvent 'Daily DNS-force reconcile finished successfully.'
        }
        else {
            $UpdateState.LastDnsForceResult = ('exit-{0}' -f $exitCode)
            $failMsg = ("Daily DNS-force reconcile exited with code {0}." -f $exitCode)
            Write-LoggerEvent -Level WARN -Message $failMsg
            if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
                $null = Send-LoginTimeSmtpAlert -Subject 'DNS-force failed' -Body $failMsg -AlertKey 'dns-force-exit'
            }
        }
        Write-UpdateState -Path $StatePath -State $UpdateState
    }
    catch {
        $UpdateState.LastDnsForceUtc = [datetime]::UtcNow.ToString('o')
        $UpdateState.LastDnsForceResult = 'error'
        Write-UpdateState -Path $StatePath -State $UpdateState
        $details = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context (
            'Daily DNS-force reconcile failed')
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'DNS-force failed' -Body $details -AlertKey 'dns-force-error'
        }
    }
}

function Update-LockSignalHiddenLauncherFromConfig {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$InstallRoot
    )

    $launcherHelper = Join-Path $InstallRoot 'src\LockSignalLauncher.ps1'
    if (-not (Test-Path -LiteralPath $launcherHelper)) {
        Write-LoggerEvent -Level WARN -Message ("Lock signal launcher helper missing after update: {0}" -f $launcherHelper)
        return
    }
    . $launcherHelper

    $watcherScript = Join-Path $InstallRoot 'src\LockSignalWatcher.ps1'
    $launcherPath = Join-Path $InstallRoot 'src\Start-LockSignalWatcher.vbs'
    if (-not (Test-Path -LiteralPath $watcherScript)) {
        Write-LoggerEvent -Level WARN -Message ("LockSignalWatcher.ps1 missing after update: {0}" -f $watcherScript)
        return
    }

    $signalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'
    if (-not [string]::IsNullOrWhiteSpace([string]$Config.LockSignalPath)) {
        $signalPath = [string]$Config.LockSignalPath
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    Write-LockSignalHiddenLauncher `
        -LauncherPath $launcherPath `
        -PowerShellExe $windowsPowerShell `
        -WatcherScript $watcherScript `
        -TargetUsername ([string]$Config.TargetUsername) `
        -SignalPath $signalPath `
        -HeartbeatSeconds 15
    Write-LoggerEvent ("Refreshed lock-signal hidden launcher: {0}" -f $launcherPath)
}

function Release-InstanceMutex {
    if (Get-Variable -Name InstanceMutex -Scope Script -ErrorAction SilentlyContinue) {
        try {
            if ($script:InstanceMutex) {
                $script:InstanceMutex.ReleaseMutex()
                $script:InstanceMutex.Dispose()
                $script:InstanceMutex = $null
            }
        }
        catch {
            # continue with restart even if release fails
        }
    }
}

function Restart-LoginTimeLoggerProcess {
    param(
        [Parameter(Mandatory)][string]$ConfigPath,
        [Parameter(Mandatory)][string]$InstallRoot,
        [string]$TaskName = 'LoginTimeLogger'
    )

    if ([string]::IsNullOrWhiteSpace($TaskName)) {
        $TaskName = $script:DefaultUpdateTaskName
    }

    Release-InstanceMutex

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($task) {
        # Exit this task instance cleanly, then start the same scheduled task again so
        # monitoring stays under Task Scheduler (crash recovery / Status remain valid).
        Write-LoggerEvent ("Restarting LoginTimeLogger via scheduled task '{0}' (delayed Start-ScheduledTask)." -f $TaskName)
        $starter = @"
Start-Sleep -Seconds 2
try {
    Start-ScheduledTask -TaskName '$TaskName' -ErrorAction Stop
}
catch {
    Start-Process -FilePath '$env:SystemRoot\System32\schtasks.exe' -ArgumentList '/Run','/TN','$TaskName' -WindowStyle Hidden | Out-Null
}
"@
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($starter))
        $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        Start-Process -FilePath $windowsPowerShell -ArgumentList @(
            '-NoProfile', '-NonInteractive', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded
        ) -WindowStyle Hidden | Out-Null
        Start-Sleep -Milliseconds 500
        exit 0
    }

    # Dev / non-task fallback: spawn replacement process directly.
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $scriptPath = Join-Path $InstallRoot 'src\LoginTimeLogger.ps1'
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        throw "Updated script not found: $scriptPath"
    }

    $arg = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $scriptPath, $ConfigPath
    Write-LoggerEvent -Level WARN -Message ("Scheduled task not found; falling back to direct process restart: {0}" -f $scriptPath)
    Start-Process -FilePath $windowsPowerShell -ArgumentList $arg -WindowStyle Hidden | Out-Null
    Start-Sleep -Seconds 1
    exit 0
}

function Invoke-LoginTimeLoggerUpdateCheck {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$InstallRoot,
        [Parameter(Mandatory)][string]$AdminAppDirectory,
        [string]$TaskName = 'LoginTimeLogger'
    )

    if (-not $Config.UpdateEnabled) {
        return
    }

    $statePath = Get-UpdateStatePath -AdminAppDirectory $AdminAppDirectory
    $updateState = Read-UpdateState -Path $statePath

    $nextDue = [datetime]::MinValue
    try {
        $nextDue = [datetime]::Parse($updateState.NextUpdateCheckUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind).ToUniversalTime()
    }
    catch {
        $nextDue = [datetime]::UtcNow
    }

    if ([datetime]::UtcNow -lt $nextDue) {
        return
    }

    Write-LoggerEvent 'Update check starting...'

    if (-not (Test-TrustedUpdateRepoUrl -RepoUrl $Config.UpdateRepoUrl)) {
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddDays(1).ToString('o')
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        $updateState.LastResult = 'untrusted-repo-url'
        Write-UpdateState -Path $statePath -State $updateState
        Write-LoggerEvent -Level ERROR -Message ("Update check blocked: UpdateRepoUrl is not an allowed HTTPS GitHub repo ({0})." -f $Config.UpdateRepoUrl)
        return
    }

    if (-not (Test-InternetAvailable)) {
        $postpone = [datetime]::UtcNow.AddMinutes(10)
        $updateState.NextUpdateCheckUtc = $postpone.ToString('o')
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        $updateState.LastResult = 'offline-postpone-10m'
        Write-UpdateState -Path $statePath -State $updateState
        Write-LoggerEvent -Level WARN -Message ("No internet connection; update check postponed until {0} (UTC)." -f $updateState.NextUpdateCheckUtc)
        return
    }

    $gitExe = Find-GitExecutable
    if (-not $gitExe) {
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddDays(1).ToString('o')
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        $updateState.LastResult = 'git-missing'
        Write-UpdateState -Path $statePath -State $updateState
        Write-LoggerEvent -Level ERROR -Message 'Update check skipped: git.exe not found on PATH or in common install locations.'
        return
    }

    try {
        $remoteSha = Get-RemoteCommitSha -GitExe $gitExe -RepoUrl $Config.UpdateRepoUrl -Branch $Config.UpdateBranch
        $localSha = Get-InstalledCommit -InstallRoot $InstallRoot
        $updateState.LastRemoteCommit = $remoteSha
        $updateState.LastLocalCommit = $localSha
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')

        if ($localSha -and ($localSha -eq $remoteSha)) {
            $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddDays(1).ToString('o')
            $updateState.LastResult = 'up-to-date'
            Write-UpdateState -Path $statePath -State $updateState
            Write-LoggerEvent ("Update check: already on latest commit {0}." -f $remoteSha)
            Invoke-DailyDnsForceLocalResolver `
                -InstallRoot $InstallRoot `
                -ClonePath ([string]$Config.UpdateClonePath) `
                -UpdateState $updateState `
                -StatePath $statePath `
                -Config $Config
            Invoke-DailyDoHFirewallBlock `
                -InstallRoot $InstallRoot `
                -ClonePath ([string]$Config.UpdateClonePath) `
                -UpdateState $updateState `
                -StatePath $statePath
            Invoke-DailyVpnFirewallBlock `
                -InstallRoot $InstallRoot `
                -ClonePath ([string]$Config.UpdateClonePath) `
                -UpdateState $updateState `
                -StatePath $statePath
            Invoke-DailyScpOutboundAllow `
                -InstallRoot $InstallRoot `
                -ClonePath ([string]$Config.UpdateClonePath) `
                -UpdateState $updateState `
                -StatePath $statePath `
                -Config $Config
            return
        }

        Write-LoggerEvent ("Update available: local={0}; remote={1}. Syncing repository..." -f $(if ($localSha) { $localSha } else { '(none)' }), $remoteSha)

        $newHead = Sync-UpdateRepository -GitExe $gitExe -RepoUrl $Config.UpdateRepoUrl -Branch $Config.UpdateBranch -ClonePath $Config.UpdateClonePath
        Publish-InstalledFilesFromRepo -ClonePath $Config.UpdateClonePath -InstallRoot $InstallRoot
        try {
            Update-LockSignalHiddenLauncherFromConfig -Config $Config -InstallRoot $InstallRoot
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context (
                'Updated monitor files but failed to refresh Start-LockSignalWatcher.vbs')
        }
        Set-InstalledCommit -InstallRoot $InstallRoot -CommitSha $newHead

        $updateState.LastLocalCommit = $newHead
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddDays(1).ToString('o')
        $updateState.LastResult = 'updated-restarting'
        Write-UpdateState -Path $statePath -State $updateState
        Write-LoggerEvent ("Updated installed files to commit {0}." -f $newHead)

        # Reconcile local DNS force + DoH/DoT + VPN + SCP-Allow rules before restart.
        Invoke-DailyDnsForceLocalResolver `
            -InstallRoot $InstallRoot `
            -ClonePath ([string]$Config.UpdateClonePath) `
            -UpdateState $updateState `
            -StatePath $statePath `
            -Config $Config
        Invoke-DailyDoHFirewallBlock `
            -InstallRoot $InstallRoot `
            -ClonePath ([string]$Config.UpdateClonePath) `
            -UpdateState $updateState `
            -StatePath $statePath
        Invoke-DailyVpnFirewallBlock `
            -InstallRoot $InstallRoot `
            -ClonePath ([string]$Config.UpdateClonePath) `
            -UpdateState $updateState `
            -StatePath $statePath
        Invoke-DailyScpOutboundAllow `
            -InstallRoot $InstallRoot `
            -ClonePath ([string]$Config.UpdateClonePath) `
            -UpdateState $updateState `
            -StatePath $statePath `
            -Config $Config

        Write-LoggerEvent 'Restarting via scheduled task after update.'
        Restart-LoginTimeLoggerProcess -ConfigPath $Config.ConfigPath -InstallRoot $InstallRoot -TaskName $TaskName
    }
    catch {
        # Network/GitHub failures: retry in 10 minutes (same as offline).
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddMinutes(10).ToString('o')
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        $updateState.LastResult = 'error-postpone-10m'
        Write-UpdateState -Path $statePath -State $updateState
        $details = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context 'Update check failed; postponing 10 minutes'
        if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
            $null = Send-LoginTimeSmtpAlert -Subject 'Update check failed' -Body $details -AlertKey 'update-check-failed'
        }
    }
}
