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
if (Get-Command Initialize-SmtpAlerts -ErrorAction SilentlyContinue) {
    $null = Initialize-SmtpAlerts -ConfigPath $ConfigPath
}

function Write-LoggerEvent {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0:yyyy-MM-dd HH:mm:ss} [{1}] {2}' -f (Get-Date), $Level, $Message
    # Never Write-Output: callers that both log and return
    # (Read-UpdateState, Sync-UpdateRepository, Read-State) would
    # otherwise receive Object[] and StrictMode property sets fail.
    Write-Host $line
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

    $cfgTargetUsername = Get-OptionalPropertyValue -InputObject $raw -Name 'TargetUsername'
    if ([string]::IsNullOrWhiteSpace([string]$cfgTargetUsername)) {
        $cfgAdminHint = Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile'
        $cfgLogHint = Get-OptionalPropertyValue -InputObject $raw -Name 'LogDirectory'
        throw @"
Config.TargetUsername is required (local SAM, DOMAIN\user, or user@upn.domain).
Config path: $Path
AdministratorProfile in file: $cfgAdminHint
LogDirectory in file: $cfgLogHint
"@
    }

    # Prefer configured admin profile (e.g. C:\Users\AdminName). Fall back to the
    # elevating user's profile when possible - do not require built-in Administrator.
    $adminHome = $null
    $cfgAdminProfile = Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgAdminProfile)) {
        $adminHome = [string]$cfgAdminProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        $adminHome = $env:USERPROFILE
    }
    else {
        $adminHome = Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
    }

    $logDirectory = Join-Path $adminHome 'LoginTimeLogs'
    $cfgLogDir = Get-OptionalPropertyValue -InputObject $raw -Name 'LogDirectory'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgLogDir)) {
        $logDirectory = [string]$cfgLogDir
    }

    $pollSeconds = 5
    $cfgPoll = Get-OptionalPropertyValue -InputObject $raw -Name 'PollIntervalSeconds'
    if ($null -ne $cfgPoll -and [int]$cfgPoll -gt 0) {
        $pollSeconds = [int]$cfgPoll
    }

    # Opt-in: self-update is off unless explicitly enabled (remote code as SYSTEM).
    $updateEnabled = $true
    $cfgUpdateEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'UpdateEnabled'
    if ($null -ne $cfgUpdateEnabled) {
        $updateEnabled = [bool]$cfgUpdateEnabled
    }

    $updateRepoUrl = 'https://github.com/ldorau/log-logged-in-time.git'
    $cfgUpdateRepo = Get-OptionalPropertyValue -InputObject $raw -Name 'UpdateRepoUrl'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgUpdateRepo)) {
        $updateRepoUrl = [string]$cfgUpdateRepo
    }

    $updateBranch = 'main'
    $cfgUpdateBranch = Get-OptionalPropertyValue -InputObject $raw -Name 'UpdateBranch'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgUpdateBranch)) {
        $updateBranch = [string]$cfgUpdateBranch
    }

    $updateClonePath = Join-Path $adminHome 'LoginTimeLogger\repo'
    $cfgUpdateClone = Get-OptionalPropertyValue -InputObject $raw -Name 'UpdateClonePath'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgUpdateClone)) {
        $updateClonePath = [string]$cfgUpdateClone
    }

    $serverDns = ''
    $cfgServerDns = Get-OptionalPropertyValue -InputObject $raw -Name 'ServerDNS'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgServerDns)) {
        $serverDns = [string]$cfgServerDns.Trim()
    }

    $scpOnLockEnabled = $false
    $cfgScpEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpOnLockEnabled'
    if ($null -ne $cfgScpEnabled) {
        $scpOnLockEnabled = [bool]$cfgScpEnabled
    }

    $scpHost = ''
    $cfgScpHost = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpHost'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpHost)) {
        $scpHost = [string]$cfgScpHost
    }

    $scpUser = ''
    $cfgScpUser = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpUser'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpUser)) {
        $scpUser = [string]$cfgScpUser
    }

    $scpRemoteDirectory = ''
    $cfgScpRemote = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpRemoteDirectory'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpRemote)) {
        $scpRemoteDirectory = [string]$cfgScpRemote
    }

    $scpPort = 22
    $cfgScpPort = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpPort'
    if ($null -ne $cfgScpPort -and [int]$cfgScpPort -gt 0) {
        $scpPort = [int]$cfgScpPort
    }

    $scpIdentityFile = ''
    $cfgScpIdentity = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpIdentityFile'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpIdentity)) {
        $scpIdentityFile = [string]$cfgScpIdentity
    }
    elseif ($scpOnLockEnabled) {
        $scpIdentityFile = Join-Path $adminHome 'LoginTimeLogger\ssh\id_ed25519'
    }

    $scpKnownHostsFile = ''
    $cfgScpKnownHosts = Get-OptionalPropertyValue -InputObject $raw -Name 'ScpKnownHostsFile'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgScpKnownHosts)) {
        $scpKnownHostsFile = [string]$cfgScpKnownHosts
    }
    elseif ($scpOnLockEnabled) {
        $scpKnownHostsFile = Join-Path $adminHome 'LoginTimeLogger\ssh\known_hosts'
    }

    $adminUsername = ''
    $cfgAdminUser = Get-OptionalPropertyValue -InputObject $raw -Name 'AdminUsername'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgAdminUser)) {
        $adminUsername = [string]$cfgAdminUser
    }

    $lockSignalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'
    $cfgLockSignal = Get-OptionalPropertyValue -InputObject $raw -Name 'LockSignalPath'
    if (-not [string]::IsNullOrWhiteSpace([string]$cfgLockSignal)) {
        $lockSignalPath = [string]$cfgLockSignal
    }

    # Every N minutes of unlocked time: warn on the target desktop, then LockWorkStation.
    # Missing key => disabled (opt-in for older runtime configs). New installs write true.
    $unlockQuotaEnabled = $false
    $cfgUnlockQuotaEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'UnlockQuotaEnabled'
    if ($null -ne $cfgUnlockQuotaEnabled) {
        $unlockQuotaEnabled = [bool]$cfgUnlockQuotaEnabled
    }
    $unlockQuotaMinutes = 30
    $cfgUnlockQuotaMinutes = Get-OptionalPropertyValue -InputObject $raw -Name 'UnlockQuotaMinutes'
    if ($null -ne $cfgUnlockQuotaMinutes -and [int]$cfgUnlockQuotaMinutes -gt 0) {
        $unlockQuotaMinutes = [int]$cfgUnlockQuotaMinutes
    }
    $unlockQuotaWarnSeconds = 3
    $cfgUnlockQuotaWarn = Get-OptionalPropertyValue -InputObject $raw -Name 'UnlockQuotaWarnSeconds'
    if ($null -ne $cfgUnlockQuotaWarn -and [int]$cfgUnlockQuotaWarn -gt 0) {
        $unlockQuotaWarnSeconds = [int]$cfgUnlockQuotaWarn
    }

    [pscustomobject]@{
        AdminUsername           = $adminUsername
        TargetUsername          = [string]$cfgTargetUsername
        AdministratorProfile    = $adminHome
        LogDirectory            = $logDirectory
        PollIntervalSeconds     = $pollSeconds
        ConfigPath              = $Path
        LockSignalPath          = $lockSignalPath
        UpdateEnabled           = $updateEnabled
        UpdateRepoUrl           = $updateRepoUrl
        UpdateBranch            = $updateBranch
        UpdateClonePath         = $updateClonePath
        ServerDNS               = $serverDns
        ScpOnLockEnabled        = $scpOnLockEnabled
        ScpHost                 = $scpHost
        ScpUser                 = $scpUser
        ScpRemoteDirectory      = $scpRemoteDirectory
        ScpPort                 = $scpPort
        ScpIdentityFile         = $scpIdentityFile
        ScpKnownHostsFile       = $scpKnownHostsFile
        UnlockQuotaEnabled      = $unlockQuotaEnabled
        UnlockQuotaMinutes      = $unlockQuotaMinutes
        UnlockQuotaWarnSeconds  = $unlockQuotaWarnSeconds
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

function New-LoggerStateObject {
    <#
      Always materialize every NoteProperty so StrictMode never throws on
      $state.Date / LastUnlockQuotaBucket after a polluted Read-State return
      (Object[]) or older JSON missing keys.
    #>
    param(
        [string]$Date = '',
        [double]$UnlockedSecondsToday = 0,
        [bool]$LastUnlocked = $false,
        [AllowNull()]$LastTransitionUtc = $null,
        [int]$LastUnlockQuotaBucket = 0
    )

    if ([string]::IsNullOrWhiteSpace($Date)) {
        $Date = (Get-Date).ToString('yyyy-MM-dd')
    }

    return [pscustomobject]@{
        Date                  = [string]$Date
        UnlockedSecondsToday  = [double]$UnlockedSecondsToday
        LastUnlocked          = [bool]$LastUnlocked
        LastTransitionUtc     = $(if ($LastTransitionUtc) { [string]$LastTransitionUtc } else { $null })
        LastUnlockQuotaBucket = [int]$LastUnlockQuotaBucket
    }
}

function ConvertTo-LoggerStateObject {
    <#
      Rebuild a full state object from any partial/polluted input (e.g. Object[]
      from a historical Write-Output log line + state hashtable).
    #>
    param(
        $State,
        [int]$UnlockQuotaMinutes = 30
    )

    if ($UnlockQuotaMinutes -lt 1) {
        $UnlockQuotaMinutes = 30
    }
    $quotaSeconds = [double]($UnlockQuotaMinutes * 60)

    # If Read-State was polluted into Object[], prefer the last object that
    # looks like state (has UnlockedSecondsToday or Date).
    if ($State -is [System.Array]) {
        $picked = $null
        foreach ($item in $State) {
            if ($null -eq $item) { continue }
            if ($null -ne $item.PSObject -and (
                    $null -ne $item.PSObject.Properties['Date'] -or
                    $null -ne $item.PSObject.Properties['UnlockedSecondsToday'])) {
                $picked = $item
            }
        }
        $State = $picked
    }

    $date = [string](Get-OptionalPropertyValue -InputObject $State -Name 'Date')
    $secondsRaw = Get-OptionalPropertyValue -InputObject $State -Name 'UnlockedSecondsToday'
    $seconds = 0.0
    if ($null -ne $secondsRaw) {
        try { $seconds = [double]$secondsRaw } catch { $seconds = 0.0 }
    }
    $lastUnlockedVal = Get-OptionalPropertyValue -InputObject $State -Name 'LastUnlocked'
    $lastUnlocked = $false
    if ($null -ne $lastUnlockedVal) {
        try { $lastUnlocked = [bool]$lastUnlockedVal } catch { $lastUnlocked = $false }
    }
    $lastTransition = Get-OptionalPropertyValue -InputObject $State -Name 'LastTransitionUtc'
    $bucketRaw = Get-OptionalPropertyValue -InputObject $State -Name 'LastUnlockQuotaBucket'
    if ($null -ne $bucketRaw) {
        try { $bucket = [int]$bucketRaw } catch {
            $bucket = [int][Math]::Floor($seconds / $quotaSeconds)
        }
    }
    else {
        # Do not retroactively fire quotas for time already accumulated.
        $bucket = [int][Math]::Floor($seconds / $quotaSeconds)
    }

    return (New-LoggerStateObject `
            -Date $date `
            -UnlockedSecondsToday $seconds `
            -LastUnlocked $lastUnlocked `
            -LastTransitionUtc $lastTransition `
            -LastUnlockQuotaBucket $bucket)
}

function Read-State {
    param(
        [Parameter(Mandatory)][string]$Path,
        [int]$UnlockQuotaMinutes = 30
    )

    if ($UnlockQuotaMinutes -lt 1) {
        $UnlockQuotaMinutes = 30
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return (New-LoggerStateObject)
    }

    try {
        $json = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        return (ConvertTo-LoggerStateObject -State $json `
                -UnlockQuotaMinutes $UnlockQuotaMinutes)
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Read-State failed for '{0}'" -f $Path)
        $null = Write-LoggerEvent -Level WARN -Message ("Corrupt state file; starting fresh.`r`n{0}" -f $details)
        return (New-LoggerStateObject)
    }
}

function Invoke-UnlockQuotaWarningAndLock {
    <#
      Shows a blocking countdown on the target user's desktop, then LockWorkStation
      inside that session via CreateProcessAsUser (SessionQuery.LaunchInUserSession).
      Waits for the child to exit successfully before the caller advances the quota bucket.
    #>
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$WarningScriptPath,
        [Parameter(Mandatory)][int]$ElapsedMinutes
    )

    if (-not (Test-Path -LiteralPath $WarningScriptPath)) {
        Write-LoggerEvent -Level WARN -Message ("Unlock-quota warning script missing: {0}" -f $WarningScriptPath)
        return $false
    }

    $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $psExe)) {
        Write-LoggerEvent -Level WARN -Message ("Unlock-quota: powershell.exe not found at {0}" -f $psExe)
        return $false
    }

    if ($ElapsedMinutes -lt 1) {
        $ElapsedMinutes = [int]$Config.UnlockQuotaMinutes
    }
    $seconds = [int]$Config.UnlockQuotaWarnSeconds
    if ($seconds -lt 1) { $seconds = 3 }
    # Hidden console; WinForms ShowDialog still appears on the interactive desktop.
    $arguments = '-NoProfile -NoLogo -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -Minutes {1} -CountdownSeconds {2}' -f `
        $WarningScriptPath, $ElapsedMinutes, $seconds

    # Wait for countdown + LockWorkStation + script teardown, with grace.
    $waitMs = ($seconds * 1000) + 15000
    $launchError = ''
    $ok = [SessionQuery]::LaunchInUserSession(
        $Config.TargetUsername, $psExe, $arguments, [ref]$launchError, $false, $waitMs)
    if (-not $ok) {
        Write-LoggerEvent -Level WARN -Message ("Unlock-quota launch failed: {0}" -f $launchError)
        return $false
    }

    Write-LoggerEvent ("Unlock-quota: showed {0}s warning for {1} unlocked minutes; lock requested in target session." -f `
            $seconds, $ElapsedMinutes)
    return $true
}

function Write-State {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)]$State
    )
    try {
        $normalized = ConvertTo-LoggerStateObject -State $State
        $tempPath = "$Path.tmp"
        ($normalized | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $tempPath -Encoding UTF8
        # Replace in place. If destination is a zeroed/locked leftover, remove
        # then rename so Move-Item -Force is not the only recovery path.
        try {
            Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        }
        catch {
            if (Test-Path -LiteralPath $Path) {
                Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
            }
            Move-Item -LiteralPath $tempPath -Destination $Path -Force -ErrorAction Stop
        }
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
    $state = ConvertTo-LoggerStateObject `
        -State (Read-State -Path $statePath -UnlockQuotaMinutes ([int]$config.UnlockQuotaMinutes)) `
        -UnlockQuotaMinutes ([int]$config.UnlockQuotaMinutes)

    $installedSrc = Join-Path $env:ProgramFiles 'LoginTimeLogger\src'
    if ([string]::Equals($scriptDir, $installedSrc, [System.StringComparison]::OrdinalIgnoreCase)) {
        $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    }
    else {
        # Dev/fallback: parent of src/
        $installRoot = Split-Path -Parent $scriptDir
    }

    Write-LoggerEvent ("LoginTimeLogger started. TargetUser={0}; LogDir={1}; Poll={2}s; Config={3}; ErrorLog={4}; UpdateEnabled={5}; ScpOnLock={6}; LockSignal={7}; UnlockQuota={8}/{9}m/{10}s" -f `
            $config.TargetUsername, $config.LogDirectory, $config.PollIntervalSeconds, $config.ConfigPath, (Get-ErrorLogPath), $config.UpdateEnabled, $config.ScpOnLockEnabled, $config.LockSignalPath, $config.UnlockQuotaEnabled, $config.UnlockQuotaMinutes, $config.UnlockQuotaWarnSeconds)
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'LoginTimeLogger startup failed' -Source 'LoginTimeLogger'
    throw
}

$lastPollUtc = [datetime]::UtcNow
$lastHeartbeatSlot = $null
$script:LastPollErrorKey = $null
$script:LastPollErrorUtc = [datetime]::MinValue

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

        # Re-wrap every poll so a polluted/partial $state cannot throw
        # PropertyNotFoundStrict on .Date under Set-StrictMode.
        $state = ConvertTo-LoggerStateObject -State $state `
            -UnlockQuotaMinutes ([int]$config.UnlockQuotaMinutes)

        if ($state.Date -ne $today) {
            if ($state.UnlockedSecondsToday -gt 0 -or $state.LastUnlocked) {
                Write-DayRollover -Config $config -State $state -EndedDate $state.Date
            }
            $state = New-LoggerStateObject -Date $today
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

            if ($config.UnlockQuotaEnabled -and [int]$config.UnlockQuotaMinutes -gt 0) {
                $quotaSeconds = [double]([int]$config.UnlockQuotaMinutes * 60)
                $newBucket = [int][Math]::Floor($state.UnlockedSecondsToday / $quotaSeconds)
                # At most one warning/lock per poll. Catch up the bucket only after a
                # successful in-session launch (avoids parallel dialogs after sleep and
                # retries when CreateProcessAsUser fails).
                if ($newBucket -gt [int]$state.LastUnlockQuotaBucket) {
                    $warnScript = Join-Path $scriptDir 'Show-UnlockQuotaWarning.ps1'
                    $elapsedMinutes = [int]($newBucket * [int]$config.UnlockQuotaMinutes)
                    $launched = $false
                    try {
                        $launched = [bool](Invoke-UnlockQuotaWarningAndLock `
                                -Config $config `
                                -WarningScriptPath $warnScript `
                                -ElapsedMinutes $elapsedMinutes)
                    }
                    catch {
                        $launched = $false
                        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'UnlockQuota' -Context (
                            'Unlock-quota warning/lock launch failed')
                    }
                    if ($launched) {
                        $state.LastUnlockQuotaBucket = $newBucket
                        Write-State -Path $statePath -State $state
                    }
                }
            }
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
        # Throttle identical poll failures (a StrictMode death spiral previously
        # wrote tens of MB to errors.log at every 5s poll).
        $errKey = [string]$_.Exception.Message
        $nowErr = [datetime]::UtcNow
        $logThis = ($errKey -ne $script:LastPollErrorKey) -or
            (($nowErr - $script:LastPollErrorUtc).TotalMinutes -ge 5)
        if ($logThis) {
            $script:LastPollErrorKey = $errKey
            $script:LastPollErrorUtc = $nowErr
            $null = Write-VerboseError -ErrorRecord $_ -Source 'LoginTimeLogger' -Context (
                "Poll loop error; target='{0}'; logDir='{1}'; statePath='{2}'; SessionQuery.LastError='{3}'" -f `
                    $config.TargetUsername, $config.LogDirectory, $statePath, $sessionLastError)
        }
    }

    Start-Sleep -Seconds $config.PollIntervalSeconds
}
