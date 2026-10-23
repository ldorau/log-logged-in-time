# Update helper for LoginTimeLogger (dot-sourced by the monitor).
# Once per day: if online, compare local installed commit to GitHub tip;
# if different, git pull (or clone) and restart via the scheduled task.
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
            NextUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
            LastUpdateCheckUtc = $null
            LastResult         = 'never'
            LastRemoteCommit   = $null
            LastLocalCommit    = $null
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
        }
    }
    catch {
        Write-LoggerEvent -Level WARN -Message ("Corrupt update-state.json; resetting. {0}" -f $_.Exception.Message)
        return [pscustomobject]@{
            NextUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
            LastUpdateCheckUtc = $null
            LastResult         = 'reset-corrupt'
            LastRemoteCommit   = $null
            LastLocalCommit    = $null
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

function Get-RemoteCommitSha {
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoUrl,
        [Parameter(Mandatory)][string]$Branch
    )

    $ref = "refs/heads/$Branch"
    $output = & $GitExe ls-remote --heads $RepoUrl $Branch 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git ls-remote failed (exit {0}): {1}" -f $LASTEXITCODE, ($output | Out-String))
    }

    foreach ($line in @($output)) {
        $text = "$line".Trim()
        if ($text -match '^(?<sha>[0-9a-fA-F]{40})\s+(?<ref>\S+)$') {
            if ($Matches['ref'] -eq $ref -or $Matches['ref'] -eq $Branch) {
                return $Matches['sha'].ToLowerInvariant()
            }
        }
    }

    throw ("Could not parse remote commit for refs/heads/{0} from git ls-remote output: {1}" -f $Branch, ($output | Out-String))
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
        $cloneOut = & $GitExe clone --branch $Branch --single-branch --depth 1 $RepoUrl $ClonePath 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("git clone failed (exit {0}): {1}" -f $LASTEXITCODE, ($cloneOut | Out-String))
        }
    }
    else {
        Write-LoggerEvent ("git fetch/pull in {0}" -f $ClonePath)
        $fetchOut = & $GitExe -C $ClonePath fetch origin $Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            throw ("git fetch failed (exit {0}): {1}" -f $LASTEXITCODE, ($fetchOut | Out-String))
        }
        # Unattended-safe equivalent of updating to newest tip after pull/fetch.
        $pullOut = & $GitExe -C $ClonePath pull --ff-only origin $Branch 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-LoggerEvent -Level WARN -Message ("git pull --ff-only failed; hard-resetting to origin/{0}. Detail: {1}" -f $Branch, ($pullOut | Out-String))
            $resetOut = & $GitExe -C $ClonePath reset --hard ("origin/{0}" -f $Branch) 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw ("git reset --hard failed (exit {0}): {1}" -f $LASTEXITCODE, ($resetOut | Out-String))
            }
        }
    }

    $head = & $GitExe -C $ClonePath rev-parse HEAD 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw ("git rev-parse HEAD failed: {0}" -f ($head | Out-String))
    }
    return ("$head").Trim().ToLowerInvariant()
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
    )
    foreach ($name in $required) {
        $from = Join-Path $srcDir $name
        if (-not (Test-Path -LiteralPath $from)) {
            throw "Required file missing in clone: $from"
        }
        Copy-Item -LiteralPath $from -Destination (Join-Path $destDir $name) -Force
    }
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
            return
        }

        Write-LoggerEvent ("Update available: local={0}; remote={1}. Syncing repository..." -f $(if ($localSha) { $localSha } else { '(none)' }), $remoteSha)

        $newHead = Sync-UpdateRepository -GitExe $gitExe -RepoUrl $Config.UpdateRepoUrl -Branch $Config.UpdateBranch -ClonePath $Config.UpdateClonePath
        Publish-InstalledFilesFromRepo -ClonePath $Config.UpdateClonePath -InstallRoot $InstallRoot
        Set-InstalledCommit -InstallRoot $InstallRoot -CommitSha $newHead

        $updateState.LastLocalCommit = $newHead
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddDays(1).ToString('o')
        $updateState.LastResult = 'updated-restarting'
        Write-UpdateState -Path $statePath -State $updateState
        Write-LoggerEvent ("Updated installed files to commit {0}. Restarting via scheduled task." -f $newHead)

        Restart-LoginTimeLoggerProcess -ConfigPath $Config.ConfigPath -InstallRoot $InstallRoot -TaskName $TaskName
    }
    catch {
        # Network/GitHub failures: retry in 10 minutes (same as offline).
        $updateState.NextUpdateCheckUtc = [datetime]::UtcNow.AddMinutes(10).ToString('o')
        $updateState.LastUpdateCheckUtc = [datetime]::UtcNow.ToString('o')
        $updateState.LastResult = 'error-postpone-10m'
        Write-UpdateState -Path $statePath -State $updateState
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context 'Update check failed; postponing 10 minutes'
    }
}
