#Requires -Version 5.1
<#
.SYNOPSIS
  Background monitor: accumulates time the target user is logged in with the screen unlocked.
.DESCRIPTION
  Intended to run elevated (SYSTEM or Administrator) via a startup Scheduled Task.
  Locked sessions are excluded. Log files are written under the Administrator profile.
#>
[CmdletBinding()]
param(
    [string]$ConfigPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Initialize before any Write-LoggerEvent call (StrictMode forbids reading unset script vars).
$script:ServiceLogPath = $null
$script:InstanceMutex = $null

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $ConfigPath = Join-Path (Split-Path -Parent $scriptDir) 'config\config.json'
}

$commonErrorPath = Join-Path $scriptDir 'Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw @"
LoginTimeLogger startup failed: shared error helper missing.
Expected file: $commonErrorPath
ScriptDir: $scriptDir
ConfigPath argument: $ConfigPath
"@
}
. $commonErrorPath
$null = Initialize-ErrorLog -ConfigPath $ConfigPath

function Write-LoggerEvent {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    Write-Output $line
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ServiceLogPath)) {
        try {
            Add-Content -LiteralPath $script:ServiceLogPath -Value $line -Encoding UTF8
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'LoginTimeLogger' -Context (
                "Write-LoggerEvent failed writing to '{0}'" -f $script:ServiceLogPath)
        }
    }
    if ($Level -eq 'ERROR' -or $Level -eq 'WARN') {
        $null = Write-ErrorMessage -Message $Message -Level $Level -Source 'LoginTimeLogger'
    }
}

function Import-SessionQueryType {
    param([Parameter(Mandatory)][string]$SourcePath)

    if (-not (Test-Path -LiteralPath $SourcePath)) {
        throw @"
SessionQuery source file not found.
Path: $SourcePath
ScriptDir: $scriptDir
"@
    }

    if (-not ('SessionQuery' -as [type])) {
        try {
            $source = Get-Content -LiteralPath $SourcePath -Raw -Encoding UTF8
            Add-Type -TypeDefinition $source -Language CSharp -ErrorAction Stop
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Add-Type failed for SessionQuery.cs at '{0}'" -f $SourcePath)
            throw (New-Object System.Exception(("Failed to compile SessionQuery from '{0}'.`r`n{1}" -f $SourcePath, $details), $_.Exception))
        }
    }
}

function Get-Config {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw @"
Config file not found.
Path: $Path
ScriptDir: $scriptDir
Current user: $env:USERNAME
"@
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Parsing config JSON failed: '{0}'" -f $Path)
        throw (New-Object System.Exception(("Invalid config JSON at '{0}'.`r`n{1}" -f $Path, $details), $_.Exception))
    }

    if ([string]::IsNullOrWhiteSpace([string]$raw.TargetUsername)) {
        throw @"
Config.TargetUsername is required (local SAM, DOMAIN\user, or user@upn.domain).
Config path: $Path
AdministratorProfile in file: $($raw.AdministratorProfile)
LogDirectory in file: $($raw.LogDirectory)
"@
    }

    # Prefer configured admin profile (e.g. C:\Users\AdminName). Fall back to the
    # elevating user's profile when possible - do not require built-in Administrator.
    $adminHome = $null
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
        $adminHome = [string]$raw.AdministratorProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        $adminHome = $env:USERPROFILE
    }
    else {
        $adminHome = Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
    }

    $logDirectory = Join-Path $adminHome 'LoginTimeLogs'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
        $logDirectory = [string]$raw.LogDirectory
    }

    $pollSeconds = 5
    if ($null -ne $raw.PollIntervalSeconds -and [int]$raw.PollIntervalSeconds -gt 0) {
        $pollSeconds = [int]$raw.PollIntervalSeconds
    }

    # Opt-in: self-update is off unless explicitly enabled (remote code as SYSTEM).
    $updateEnabled = $true
    if ($null -ne $raw.UpdateEnabled) {
        $updateEnabled = [bool]$raw.UpdateEnabled
    }

    $updateRepoUrl = 'https://github.com/ldorau/log-logged-in-time.git'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.UpdateRepoUrl)) {
        $updateRepoUrl = [string]$raw.UpdateRepoUrl
    }

    $updateBranch = 'main'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.UpdateBranch)) {
        $updateBranch = [string]$raw.UpdateBranch
    }

    $updateClonePath = Join-Path $adminHome 'LoginTimeLogger\repo'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.UpdateClonePath)) {
        $updateClonePath = [string]$raw.UpdateClonePath
    }

    $scpOnLockEnabled = $false
    if ($null -ne $raw.ScpOnLockEnabled) {
        $scpOnLockEnabled = [bool]$raw.ScpOnLockEnabled
    }

    $scpHost = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpHost)) {
        $scpHost = [string]$raw.ScpHost
    }

    $scpUser = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpUser)) {
        $scpUser = [string]$raw.ScpUser
    }

    $scpRemoteDirectory = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpRemoteDirectory)) {
        $scpRemoteDirectory = [string]$raw.ScpRemoteDirectory
    }

    $scpPort = 22
    if ($null -ne $raw.ScpPort -and [int]$raw.ScpPort -gt 0) {
        $scpPort = [int]$raw.ScpPort
    }

    $scpIdentityFile = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpIdentityFile)) {
        $scpIdentityFile = [string]$raw.ScpIdentityFile
    }
    elseif ($scpOnLockEnabled) {
        $scpIdentityFile = Join-Path $adminHome 'LoginTimeLogger\ssh\id_ed25519'
    }

    $scpKnownHostsFile = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpKnownHostsFile)) {
        $scpKnownHostsFile = [string]$raw.ScpKnownHostsFile
    }
    elseif ($scpOnLockEnabled) {
        $scpKnownHostsFile = Join-Path $adminHome 'LoginTimeLogger\ssh\known_hosts'
    }

    $adminUsername = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdminUsername)) {
        $adminUsername = [string]$raw.AdminUsername
    }

    $lockSignalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.LockSignalPath)) {
        $lockSignalPath = [string]$raw.LockSignalPath
    }

    [pscustomobject]@{
        AdminUsername        = $adminUsername
        TargetUsername       = [string]$raw.TargetUsername
        AdministratorProfile = $adminHome
        LogDirectory         = $logDirectory
        PollIntervalSeconds  = $pollSeconds
        ConfigPath           = $Path
        LockSignalPath       = $lockSignalPath
        UpdateEnabled        = $updateEnabled
        UpdateRepoUrl        = $updateRepoUrl
        UpdateBranch         = $updateBranch
        UpdateClonePath      = $updateClonePath
        ScpOnLockEnabled     = $scpOnLockEnabled
        ScpHost              = $scpHost
        ScpUser              = $scpUser
        ScpRemoteDirectory   = $scpRemoteDirectory
        ScpPort              = $scpPort
        ScpIdentityFile      = $scpIdentityFile
        ScpKnownHostsFile    = $scpKnownHostsFile
    }
}

function Initialize-SecureLogDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)]
        [Alias('DeniedUsername')]
        [string]$TargetUsername,
        [Parameter(Mandatory)][string]$AdministratorProfile,
        [string]$AdminUsername = ''
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        }

        $acl = Get-Acl -LiteralPath $Directory
        $acl.SetAccessRuleProtection($true, $false)

        foreach ($rule in @($acl.Access)) {
            $null = $acl.RemoveAccessRule($rule)
        }

        # Allow the admin account + SYSTEM. Prefer AdminUsername (DOMAIN\user / UPN);
        # fall back to ProfileList match on AdministratorProfile (works under SYSTEM).
        # Target gets ReadAndExecute only (Status / Get-LockedTime as measured user).
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $allowedAdminSid = $null
        if (-not [string]::IsNullOrWhiteSpace($AdminUsername)) {
            $allowedAdminSid = Resolve-WindowsAccountSid -UserName $AdminUsername -ProfilePath $AdministratorProfile
        }
        if (-not $allowedAdminSid) {
            $allowedAdminSid = Resolve-WindowsAccountSid -UserName $AdministratorProfile -ProfilePath $AdministratorProfile
        }
        if (-not $allowedAdminSid) {
            $adminLeaf = Split-Path -Leaf (Get-NormalizedProfilePath -Path $AdministratorProfile)
            throw ("Could not resolve administrator account for ACL Allow. AdminUsername='{0}'; profile='{1}'; leaf='{2}'. Tried NTAccount and ProfileList." -f `
                    $AdminUsername, $AdministratorProfile, $adminLeaf)
        }

        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $allowedAdminSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidSystem, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))

        $targetSid = Resolve-WindowsAccountSid -UserName $TargetUsername -ProfilePath $AdministratorProfile
        if ($targetSid) {
            if ($targetSid.Value -eq $allowedAdminSid.Value) {
                # Allowed for testing when admin and measured user are the same account.
                Write-LoggerEvent -Level INFO -Message (
                    "TargetUsername '{0}' matches admin profile account; skipping target read ACE on '{1}' (OK for testing)." -f `
                        $TargetUsername, $Directory)
            }
            else {
                try {
                    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                                $targetSid, 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
                }
                catch {
                    $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                        "Adding target read ACE failed; user='{0}'; sid='{1}'; directory='{2}'" -f `
                            $TargetUsername, $targetSid.Value, $Directory)
                    Write-LoggerEvent -Level WARN -Message $details
                }
            }
        }
        else {
            Write-LoggerEvent -Level WARN -Message (
                "Could not resolve '{0}' to a SID for read ACE on '{1}'." -f $TargetUsername, $Directory)
        }

        Set-Acl -LiteralPath $Directory -AclObject $acl
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Initialize-SecureLogDirectory failed; directory='{0}'; targetUser='{1}'" -f $Directory, $TargetUsername)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}

function Initialize-SecureSshDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$AdministratorProfile,
        [string]$AdminUsername = ''
    )

    try {
        if (-not (Test-Path -LiteralPath $Directory)) {
            New-Item -ItemType Directory -Path $Directory -Force | Out-Null
        }

        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $allowedAdminSid = $null
        if (-not [string]::IsNullOrWhiteSpace($AdminUsername)) {
            $allowedAdminSid = Resolve-WindowsAccountSid -UserName $AdminUsername -ProfilePath $AdministratorProfile
        }
        if (-not $allowedAdminSid) {
            $allowedAdminSid = Resolve-WindowsAccountSid -UserName $AdministratorProfile -ProfilePath $AdministratorProfile
        }
        if (-not $allowedAdminSid) {
            throw ("Could not resolve administrator account for SSH ACL. AdminUsername='{0}'; profile='{1}'." -f `
                    $AdminUsername, $AdministratorProfile)
        }

        $acl = Get-Acl -LiteralPath $Directory
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($acl.Access)) {
            $null = $acl.RemoveAccessRule($rule)
        }
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $allowedAdminSid, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $sidSystem, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        Set-Acl -LiteralPath $Directory -AclObject $acl
        Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try { Set-Acl -LiteralPath $_.FullName -AclObject $acl } catch { }
        }
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Initialize-SecureSshDirectory failed; directory='{0}'" -f $Directory)
        Write-LoggerEvent -Level WARN -Message $details
    }
}

function Get-StatePath {
    param([Parameter(Mandatory)][string]$LogDirectory)
    Join-Path $LogDirectory 'state.json'
}

function Get-DailyLogPath {
    param(
        [Parameter(Mandatory)][string]$LogDirectory,
        [Parameter(Mandatory)][datetime]$Date
    )
    Join-Path $LogDirectory ('unlocked-time-{0:yyyy-MM-dd}.log' -f $Date)
}

function Get-SummaryPath {
    param([Parameter(Mandatory)][string]$LogDirectory)
    Join-Path $LogDirectory 'unlocked-time-summary.csv'
}

function Read-State {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]@{
            Date                 = (Get-Date).ToString('yyyy-MM-dd')
            UnlockedSecondsToday = 0
            LastUnlocked         = $false
            LastTransitionUtc    = $null
        }
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return [pscustomobject]@{
            Date                 = [string]$json.Date
            UnlockedSecondsToday = [double]$json.UnlockedSecondsToday
            LastUnlocked         = [bool]$json.LastUnlocked
            LastTransitionUtc    = $(if ($json.LastTransitionUtc) { [string]$json.LastTransitionUtc } else { $null })
        }
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Read-State failed for '{0}'" -f $Path)
        Write-LoggerEvent -Level WARN -Message ("Corrupt state file; starting fresh.`r`n{0}" -f $details)
        return [pscustomobject]@{
            Date                 = (Get-Date).ToString('yyyy-MM-dd')
            UnlockedSecondsToday = 0
            LastUnlocked         = $false
            LastTransitionUtc    = $null
        }
    }
}

function Write-State {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )
    try {
        $tempPath = "$Path.tmp"
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tempPath -Encoding UTF8
        Move-Item -LiteralPath $tempPath -Destination $Path -Force
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Write-State failed for '{0}'" -f $Path)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}

function Ensure-SummaryHeader {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        try {
            Set-Content -LiteralPath $Path -Value 'Date,UnlockedSeconds,UnlockedHours,TargetUsername' -Encoding UTF8
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Ensure-SummaryHeader failed for '{0}'" -f $Path)
            throw (New-Object System.Exception($details, $_.Exception))
        }
    }
}

function Format-Duration {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    # Use Floor(TotalHours), not [int] cast: PowerShell casts double->int with rounding,
    # so [int]0.5..0.99 becomes 1 and cumulative_today jumps from 00:mm:ss to 01:mm:ss
    # after ~30 minutes of unlocked time (display bug; state seconds stayed correct).
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Write-DailyLogLine {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Line
    )
    try {
        Add-Content -LiteralPath $Path -Value $Line -Encoding UTF8
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Write-DailyLogLine failed for '{0}'" -f $Path)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}

function Write-DayRollover {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$EndedDate
    )

    try {
        $summaryPath = Get-SummaryPath -LogDirectory $Config.LogDirectory
        Ensure-SummaryHeader -Path $summaryPath

        $hours = [Math]::Round($State.UnlockedSecondsToday / 3600.0, 4)
        $row = '{0},{1:F0},{2},{3}' -f $EndedDate, $State.UnlockedSecondsToday, $hours, $Config.TargetUsername
        Add-Content -LiteralPath $summaryPath -Value $row -Encoding UTF8

        $dailyPath = Get-DailyLogPath -LogDirectory $Config.LogDirectory -Date ([datetime]::ParseExact($EndedDate, 'yyyy-MM-dd', $null))
        Write-DailyLogLine -Path $dailyPath -Line (
            '{0:yyyy-MM-dd HH:mm:ss} | DAY_TOTAL | unlocked={1} ({2})' -f (Get-Date), (Format-Duration $State.UnlockedSecondsToday), ("{0:F2}h" -f $hours)
        )
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Write-DayRollover failed; endedDate='{0}'; logDir='{1}'" -f $EndedDate, $Config.LogDirectory)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}

# --- single-instance guard (survives scheduled-task restart after updates) ---
$script:InstanceMutex = $null
try {
    $createdNew = $false
    $script:InstanceMutex = New-Object System.Threading.Mutex(
        $false,
        'Global\LoginTimeLogger.Monitor',
        [ref]$createdNew)
    # Wait briefly so a restarting instance can exit and release the mutex.
    if (-not $script:InstanceMutex.WaitOne(15000, $false)) {
        Write-Host 'Another LoginTimeLogger instance is already running; exiting.'
        exit 0
    }
    # Allow Administrators + SYSTEM to open the Global mutex so Status.ps1 (elevated)
    # can probe it. Default SYSTEM-created DACLs often deny other admins (access denied).
    # Refresh after acquire so a task restart repairs an older restrictive ACL.
    try {
        if ($script:InstanceMutex.PSObject.Methods.Name -contains 'SetAccessControl') {
            $mutexSecurity = New-Object System.Security.AccessControl.MutexSecurity
            $mutexRights = [System.Security.AccessControl.MutexRights]::FullControl
            foreach ($sidValue in @('S-1-5-18', 'S-1-5-32-544')) {
                $sid = New-Object System.Security.Principal.SecurityIdentifier($sidValue)
                $mutexSecurity.AddAccessRule((New-Object System.Security.AccessControl.MutexAccessRule(
                            $sid, $mutexRights, [System.Security.AccessControl.AccessControlType]::Allow)))
            }
            $script:InstanceMutex.SetAccessControl($mutexSecurity)
        }
    }
    catch {
        Write-Host ("WARNING: could not set monitor mutex ACL (Status may not see it): {0}" -f $_.Exception.Message)
    }
}
catch {
    Write-Host ("ERROR: could not acquire instance mutex: {0}" -f $_.Exception.Message)
    throw
}

# --- main ---
try {
    $config = Get-Config -Path $ConfigPath
    $null = Initialize-ErrorLog -AdministratorProfile $config.AdministratorProfile
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    $updateHelper = Join-Path $scriptDir 'Update-Check.ps1'
    if (-not (Test-Path -LiteralPath $updateHelper)) {
        throw "Update-Check.ps1 missing at '$updateHelper'."
    }
    . $updateHelper

    $scpHelper = Join-Path $scriptDir 'Scp-OnLock.ps1'
    if (-not (Test-Path -LiteralPath $scpHelper)) {
        throw "Scp-OnLock.ps1 missing at '$scpHelper'."
    }
    . $scpHelper

    $csPath = Join-Path $scriptDir 'SessionQuery.cs'
    Import-SessionQueryType -SourcePath $csPath
    if (-not [string]::IsNullOrWhiteSpace([string]$config.LockSignalPath)) {
        [SessionQuery]::LockSignalPath = [string]$config.LockSignalPath
    }

    Initialize-SecureLogDirectory -Directory $config.LogDirectory `
        -TargetUsername $config.TargetUsername `
        -AdministratorProfile $config.AdministratorProfile `
        -AdminUsername $config.AdminUsername

    $adminAppDirectory = Join-Path $config.AdministratorProfile 'LoginTimeLogger'
    Initialize-SecureLogDirectory -Directory $adminAppDirectory `
        -TargetUsername $config.TargetUsername `
        -AdministratorProfile $config.AdministratorProfile `
        -AdminUsername $config.AdminUsername
    Initialize-SecureSshDirectory `
        -Directory (Join-Path $adminAppDirectory 'ssh') `
        -AdministratorProfile $config.AdministratorProfile `
        -AdminUsername $config.AdminUsername

    $script:ServiceLogPath = Join-Path $config.LogDirectory 'service.log'
    $statePath = Get-StatePath -LogDirectory $config.LogDirectory
    $state = Read-State -Path $statePath

    $installedSrc = Join-Path $env:ProgramFiles 'LoginTimeLogger\src'
    if ([string]::Equals($scriptDir, $installedSrc, [System.StringComparison]::OrdinalIgnoreCase)) {
        $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    }
    else {
        # Dev/fallback: parent of src/
        $installRoot = Split-Path -Parent $scriptDir
    }

    Write-LoggerEvent ("LoginTimeLogger started. TargetUser={0}; LogDir={1}; Poll={2}s; Config={3}; ErrorLog={4}; UpdateEnabled={5}; ScpOnLock={6}; LockSignal={7}" -f `
            $config.TargetUsername, $config.LogDirectory, $config.PollIntervalSeconds, $config.ConfigPath, (Get-ErrorLogPath), $config.UpdateEnabled, $config.ScpOnLockEnabled, $config.LockSignalPath)
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'LoginTimeLogger startup failed' -Source 'LoginTimeLogger'
    throw
}

$lastPollUtc = [datetime]::UtcNow
$lastHeartbeatSlot = $null

while ($true) {
    try {
        # Daily (or postponed) self-update against GitHub tip.
        try {
            Invoke-LoginTimeLoggerUpdateCheck -Config $config -InstallRoot $installRoot -AdminAppDirectory $adminAppDirectory
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UpdateCheck' -Context 'Unexpected update-check failure'
        }

        $nowLocal = Get-Date
        $nowUtc = [datetime]::UtcNow
        $today = $nowLocal.ToString('yyyy-MM-dd')

        if ($state.Date -ne $today) {
            if ($state.UnlockedSecondsToday -gt 0 -or $state.LastUnlocked) {
                Write-DayRollover -Config $config -State $state -EndedDate $state.Date
            }
            $state = [pscustomobject]@{
                Date                 = $today
                UnlockedSecondsToday = 0
                LastUnlocked         = $false
                LastTransitionUtc    = $null
            }
        }

        $elapsed = ($nowUtc - $lastPollUtc).TotalSeconds
        # Cap delta so sleep/hibernate gaps are not counted as unlocked time.
        $maxCredit = [Math]::Max($config.PollIntervalSeconds * 2, 15)
        if ($elapsed -gt $maxCredit) {
            $elapsed = $config.PollIntervalSeconds
        }
        if ($elapsed -lt 0) {
            $elapsed = 0
        }

        try {
            $unlocked = [SessionQuery]::IsUserUnlocked($config.TargetUsername)
        }
        catch {
            $sessionLastError = $null
            try { $sessionLastError = [SessionQuery]::LastError } catch { $sessionLastError = '(unavailable)' }
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "SessionQuery.IsUserUnlocked failed; target='{0}'; SessionQuery.LastError='{1}'" -f `
                    $config.TargetUsername, $sessionLastError)
            throw (New-Object System.Exception($details, $_.Exception))
        }

        $dailyPath = Get-DailyLogPath -LogDirectory $config.LogDirectory -Date $nowLocal

        if ($unlocked) {
            $state.UnlockedSecondsToday += $elapsed
        }

        if ($unlocked -ne $state.LastUnlocked) {
            $eventName = if ($unlocked) { 'UNLOCKED_ACTIVE' } else { 'LOCKED_OR_AWAY' }
            $lockSource = '(unknown)'
            $wtsFlags = -1
            try { $lockSource = [SessionQuery]::LastLockSource } catch { }
            try { $wtsFlags = [SessionQuery]::LastWtsSessionFlags } catch { }
            $line = '{0:yyyy-MM-dd HH:mm:ss} | {1} | cumulative_today={2} | LockSource={3} | WtsFlags={4}' -f `
                $nowLocal, $eventName, (Format-Duration $state.UnlockedSecondsToday), $lockSource, $wtsFlags
            Write-DailyLogLine -Path $dailyPath -Line $line
            Write-LoggerEvent $line
            $state.LastTransitionUtc = $nowUtc.ToString('o')
            $state.LastUnlocked = $unlocked

            # On lock (or leaving unlocked-active), push today's time log + error log via scp.
            if (-not $unlocked) {
                Write-State -Path $statePath -State $state
                try {
                    Invoke-ScpLogCopyOnLock `
                        -Config $config `
                        -TimeLogPath $dailyPath `
                        -ErrorLogPath (Get-ErrorLogPath)
                }
                catch {
                    $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'ScpOnLock' -Context 'Unexpected SCP-on-lock failure'
                }
            }
        }

        # Periodic heartbeat once every 15 minutes.
        $heartbeatSlot = '{0:yyyy-MM-dd HH}:{1:00}' -f $nowLocal, ([int]([Math]::Floor($nowLocal.Minute / 15) * 15))
        if ($heartbeatSlot -ne $lastHeartbeatSlot) {
            $hb = '{0:yyyy-MM-dd HH:mm:ss} | HEARTBEAT | unlocked={1} | cumulative_today={2}' -f `
                $nowLocal, $unlocked, (Format-Duration $state.UnlockedSecondsToday)
            Write-DailyLogLine -Path $dailyPath -Line $hb
            $lastHeartbeatSlot = $heartbeatSlot
        }

        Write-State -Path $statePath -State $state
        $lastPollUtc = $nowUtc
    }
    catch {
        # Advance the poll clock on failure so a partial credit + retry cannot
        # double-count the same wall interval after the next successful loop.
        $lastPollUtc = [datetime]::UtcNow
        $sessionLastError = $null
        try { $sessionLastError = [SessionQuery]::LastError } catch { $sessionLastError = '(unavailable)' }
        $null = Write-VerboseError -ErrorRecord $_ -Source 'LoginTimeLogger' -Context (
            "Poll loop error; target='{0}'; logDir='{1}'; statePath='{2}'; SessionQuery.LastError='{3}'" -f `
                $config.TargetUsername, $config.LogDirectory, $statePath, $sessionLastError)
    }

    Start-Sleep -Seconds $config.PollIntervalSeconds
}
