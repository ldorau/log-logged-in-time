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
    if ($script:ServiceLogPath) {
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

    $adminHome = Join-Path $env:SystemDrive 'Users\Administrator'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
        $adminHome = [string]$raw.AdministratorProfile
    }

    $logDirectory = Join-Path $adminHome 'LoginTimeLogs'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.LogDirectory)) {
        $logDirectory = [string]$raw.LogDirectory
    }

    $pollSeconds = 5
    if ($null -ne $raw.PollIntervalSeconds -and [int]$raw.PollIntervalSeconds -gt 0) {
        $pollSeconds = [int]$raw.PollIntervalSeconds
    }

    [pscustomobject]@{
        TargetUsername       = [string]$raw.TargetUsername
        AdministratorProfile = $adminHome
        LogDirectory         = $logDirectory
        PollIntervalSeconds  = $pollSeconds
        ConfigPath           = $Path
    }
}

function Initialize-SecureLogDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$DeniedUsername
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

        $adminRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $systemRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
            'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($adminRule)
        $acl.AddAccessRule($systemRule)

        try {
            $denyRule = New-Object System.Security.AccessControl.FileSystemAccessRule(
                $DeniedUsername, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Deny')
            $acl.AddAccessRule($denyRule)
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "Adding Deny ACE failed; user='{0}'; directory='{1}'" -f $DeniedUsername, $Directory)
            Write-LoggerEvent -Level WARN -Message $details
        }

        Set-Acl -LiteralPath $Directory -AclObject $acl
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Initialize-SecureLogDirectory failed; directory='{0}'; deniedUser='{1}'" -f $Directory, $DeniedUsername)
        throw (New-Object System.Exception($details, $_.Exception))
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
        ($State | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $Path -Encoding UTF8
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
    '{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
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

# --- main ---
try {
    $config = Get-Config -Path $ConfigPath
    $null = Initialize-ErrorLog -AdministratorProfile $config.AdministratorProfile
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    $csPath = Join-Path $scriptDir 'SessionQuery.cs'
    Import-SessionQueryType -SourcePath $csPath

    Initialize-SecureLogDirectory -Directory $config.LogDirectory -DeniedUsername $config.TargetUsername

    $script:ServiceLogPath = Join-Path $config.LogDirectory 'service.log'
    $statePath = Get-StatePath -LogDirectory $config.LogDirectory
    $state = Read-State -Path $statePath

    Write-LoggerEvent ("LoginTimeLogger started. TargetUser={0}; LogDir={1}; Poll={2}s; Config={3}; ErrorLog={4}" -f `
            $config.TargetUsername, $config.LogDirectory, $config.PollIntervalSeconds, $config.ConfigPath, (Get-ErrorLogPath))
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'LoginTimeLogger startup failed' -Source 'LoginTimeLogger'
    throw
}

$lastPollUtc = [datetime]::UtcNow
$lastHeartbeatSlot = $null

while ($true) {
    try {
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
            $line = '{0:yyyy-MM-dd HH:mm:ss} | {1} | cumulative_today={2}' -f `
                $nowLocal, $eventName, (Format-Duration $state.UnlockedSecondsToday)
            Write-DailyLogLine -Path $dailyPath -Line $line
            Write-LoggerEvent $line
            $state.LastTransitionUtc = $nowUtc.ToString('o')
            $state.LastUnlocked = $unlocked
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
        $sessionLastError = $null
        try { $sessionLastError = [SessionQuery]::LastError } catch { $sessionLastError = '(unavailable)' }
        $null = Write-VerboseError -ErrorRecord $_ -Source 'LoginTimeLogger' -Context (
            "Poll loop error; target='{0}'; logDir='{1}'; statePath='{2}'; SessionQuery.LastError='{3}'" -f `
                $config.TargetUsername, $config.LogDirectory, $statePath, $sessionLastError)
    }

    Start-Sleep -Seconds $config.PollIntervalSeconds
}
