#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs LoginTimeLogger to start at system boot with highest privileges.
.DESCRIPTION
  Takes the administrative account (install/config owner) and the measured
  user account as required arguments. Other settings come from
  config\config.json. Runtime config is stored under the admin profile
  (ACL-protected). Creates a Scheduled Task that runs as SYSTEM at startup.
.PARAMETER AdminUsername
  Administrative Windows account that owns install/config/logs
  (e.g. AdminName). Profile path defaults to C:\Users\<sam-leaf>.
.PARAMETER TargetUsername
  Windows account whose unlocked login time will be measured.
  For testing, this may be the same as AdminUsername (Deny ACL is skipped).
.EXAMPLE
  .\scripts\Install.ps1 -AdminUsername AdminName -TargetUsername UserName -StartNow
.EXAMPLE
  .\scripts\Install.ps1 AdminName UserName -StartNow
.EXAMPLE
  # Testing with one account for both roles:
  .\scripts\Install.ps1 -AdminUsername AdminName -TargetUsername AdminName -StartNow
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [Alias('AdministratorUsername')]
    [string]$AdminUsername,

    [Parameter(Mandatory, Position = 1)]
    [string]$TargetUsername,

    [string]$TaskName = 'LoginTimeLogger',
    [switch]$StartNow
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw @"
Install failed: shared error helper missing.
Expected: $commonErrorPath
RepoRoot: $repoRoot
Script: $PSCommandPath
"@
}
. $commonErrorPath

$templateConfigForLog = Join-Path $repoRoot 'config\config.json'
$null = Initialize-ErrorLog -ConfigPath $templateConfigForLog
Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

function Write-CheckResult {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][bool]$Ok,
        [string]$Detail = ''
    )
    $status = if ($Ok) { 'OK' } else { 'FAIL' }
    if ($Detail) {
        Write-Host ("  [{0}] {1} - {2}" -f $status, $Name, $Detail)
    }
    else {
        Write-Host ("  [{0}] {1}" -f $status, $Name)
    }
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Resolve-AccountSid {
    <#
    .SYNOPSIS
      Resolves an account name or profile path to a SecurityIdentifier for ACLs.
      Accepts: user | DOMAIN\user | user@upn.domain | .\user | C:\Users\...
    #>
    param(
        [Parameter(Mandatory)][string]$UserName,
        [string]$ProfilePath = ''
    )

    return (Resolve-WindowsAccountSid -UserName $UserName -ProfilePath $ProfilePath)
}

function Test-AccountExists {
    <#
    .SYNOPSIS
      Returns true if the account resolves to a Windows account SID (ACL-usable).
      Accepts: user | DOMAIN\user | user@upn.domain | profile path
    #>
    param(
        [Parameter(Mandatory)][string]$UserName,
        [string]$ProfilePath = ''
    )

    $sid = Resolve-AccountSid -UserName $UserName -ProfilePath $ProfilePath
    return ($null -ne $sid)
}

function New-SidFileSystemAccessRule {
    param(
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid,
        [Parameter(Mandatory)][string]$Rights,
        [Parameter(Mandatory)][string]$InheritanceFlags,
        [Parameter(Mandatory)][string]$PropagationFlags,
        [Parameter(Mandatory)][string]$AccessControlType
    )

    return New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Sid, $Rights, $InheritanceFlags, $PropagationFlags, $AccessControlType)
}

function Get-AccountNameFromProfilePath {
    <#
    .SYNOPSIS
      Derives the Windows account name from a profile path (C:\Users\AdminName -> AdminName).
    #>
    param([Parameter(Mandatory)][string]$ProfilePath)

    $normalized = Get-NormalizedProfilePath -Path $ProfilePath
    if ([string]::IsNullOrWhiteSpace($normalized)) {
        return $null
    }
    return (Split-Path -Leaf $normalized)
}

function Get-ProfilePathForAccount {
    <#
    .SYNOPSIS
      Resolves the local profile folder for an account name, UPN, DOMAIN\user, or path.
      Prefers ProfileList when the account SID is known; otherwise C:\Users\<sam>.
    #>
    param([Parameter(Mandatory)][string]$AccountName)

    $trimmed = $AccountName.Trim()
    if (Test-LooksLikeFilePath -Value $trimmed) {
        return (Get-NormalizedProfilePath -Path $trimmed)
    }

    $sid = Resolve-AccountSid -UserName $trimmed
    if ($sid) {
        $fromReg = Get-ProfilePathForSid -Sid $sid
        if (-not [string]::IsNullOrWhiteSpace($fromReg)) {
            return $fromReg
        }
    }

    $leaf = Get-AccountSamLeaf -UserName $trimmed
    if ([string]::IsNullOrWhiteSpace($leaf)) {
        throw ("Could not derive profile folder name from account '{0}'." -f $AccountName)
    }
    return (Join-Path $env:SystemDrive ('Users\{0}' -f $leaf))
}

function Resolve-AdministratorAccountSid {
    <#
    .SYNOPSIS
      Resolves the admin account that owns AdministratorProfile (not BUILTIN\Administrators).
    #>
    param(
        [Parameter(Mandatory)][string]$AdministratorProfile,
        [string]$AdminUsername = ''
    )

    if (-not [string]::IsNullOrWhiteSpace($AdminUsername)) {
        $sid = Resolve-AccountSid -UserName $AdminUsername -ProfilePath $AdministratorProfile
        if ($sid) {
            return $sid
        }
    }
    return (Resolve-AccountSid -UserName $AdministratorProfile -ProfilePath $AdministratorProfile)
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

function Update-ProcessPathFromMachine {
    # Git's installer updates the Machine PATH; refresh this process so Get-Command can see it.
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($machine -or $user) {
            $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
        }
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context 'Refreshing process PATH after Git install failed')
    }
}

function Test-GitInstallerAuthenticode {
    param([Parameter(Mandatory)][string]$InstallerPath)

    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($signature.Status -ne 'Valid') {
        throw ("Git installer Authenticode signature is not Valid (Status={0}; StatusMessage={1})." -f `
                $signature.Status, $signature.StatusMessage)
    }

    $subject = ''
    if ($signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }
    $allowedPublisherPatterns = @(
        'Johannes Schindelin'
        'Git for Windows'
        'GitHub, Inc'
        'Microsoft Corporation'
    )
    $publisherOk = $false
    foreach ($pattern in $allowedPublisherPatterns) {
        if ($subject -like ("*{0}*" -f $pattern)) {
            $publisherOk = $true
            break
        }
    }
    if (-not $publisherOk) {
        throw ("Git installer is signed, but publisher is not allowed. Subject={0}" -f $subject)
    }

    Write-Host ("  Authenticode OK: {0}" -f $subject)
}

function Install-GitForWindows {
    <#
    .SYNOPSIS
      Downloads the latest Git for Windows installer, verifies Authenticode, then silent-installs.
    #>
    Write-Host '  Git not found. Downloading and installing Git for Windows...'

    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context 'Enabling TLS 1.2 for Git download')
    }

    $archTag = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
    $apiUrl = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'LoginTimeLogger-Install'
    }

    try {
        $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("GET {0}" -f $apiUrl)
        throw (New-Object System.Exception(
                ("Could not query Git for Windows releases.`r`n{0}" -f $details), $_.Exception))
    }

    $asset = @(
        $release.assets |
            Where-Object { $_.name -match ("^Git-.+-{0}\.exe$" -f [regex]::Escape($archTag)) } |
            Select-Object -First 1
    )[0]
    if (-not $asset) {
        throw ("No Git for Windows {0} installer found in the latest GitHub release." -f $archTag)
    }

    $downloadUrl = [string]$asset.browser_download_url
    $installerName = [string]$asset.name
    $installerPath = Join-Path $env:TEMP $installerName
    Write-Host ("  Downloading {0}..." -f $installerName)

    try {
        Invoke-WebRequest -Uri $downloadUrl -OutFile $installerPath -UseBasicParsing
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Download {0}" -f $downloadUrl)
        throw (New-Object System.Exception(
                ("Could not download Git for Windows installer.`r`n{0}" -f $details), $_.Exception))
    }

    if (-not (Test-Path -LiteralPath $installerPath)) {
        throw ("Git installer download completed but file is missing: {0}" -f $installerPath)
    }

    try {
        Test-GitInstallerAuthenticode -InstallerPath $installerPath
    }
    catch {
        try { Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue } catch { }
        throw
    }

    # Inno Setup silent flags; PathOption=Cmd adds git.exe to PATH for cmd/PowerShell.
    $installArgs = @(
        '/VERYSILENT'
        '/NORESTART'
        '/NOCANCEL'
        '/SP-'
        '/CLOSEAPPLICATIONS'
        '/RESTARTAPPLICATIONS'
        '/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh'
        '/o:PathOption=Cmd'
    )
    Write-Host '  Running silent Git for Windows installer (may take a minute)...'
    $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
    if ($proc.ExitCode -ne 0) {
        throw ("Git for Windows installer exited with code {0}." -f $proc.ExitCode)
    }

    try {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context (
                "Cleanup of Git installer '{0}' failed" -f $installerPath))
    }

    Update-ProcessPathFromMachine
    $gitPath = Find-GitExecutable
    if (-not $gitPath) {
        throw 'Git for Windows installer finished, but git.exe was not found afterward.'
    }
    return $gitPath
}

function Find-ScpExecutable {
    $cmd = Get-Command scp.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    $candidates = @(
        (Join-Path $env:SystemRoot 'System32\OpenSSH\scp.exe')
        (Join-Path $env:SystemRoot 'Sysnative\OpenSSH\scp.exe')
        (Join-Path $env:ProgramFiles 'OpenSSH\scp.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Install-OpenSshClient {
    <#
    .SYNOPSIS
      Installs the Windows OpenSSH Client optional feature (provides scp.exe).
    #>
    Write-Host '  OpenSSH Client not found. Installing Windows capability OpenSSH.Client...'

    $capabilityName = 'OpenSSH.Client~~~~0.0.1.0'
    try {
        $result = Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop
        Write-Verbose -Message ("Add-WindowsCapability State={0}; RestartNeeded={1}" -f $result.State, $result.RestartNeeded)
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context ("Add-WindowsCapability -Name {0}" -f $capabilityName)
        throw (New-Object System.Exception(
                ("Could not install OpenSSH Client capability.`r`n{0}" -f $details), $_.Exception))
    }

    Update-ProcessPathFromMachine
    $scpPath = Find-ScpExecutable
    if (-not $scpPath) {
        throw 'OpenSSH Client capability install finished, but scp.exe was not found afterward. A reboot may be required.'
    }
    return $scpPath
}

function Test-InstallPrerequisites {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MonitorScript,
        [Parameter(Mandatory)][string]$TemplateConfigPath,
        [Parameter(Mandatory)][string]$CsPath,
        [Parameter(Mandatory)][string]$AdminUsername,
        [Parameter(Mandatory)][string]$TargetUsername
    )

    Write-Host 'Checking required software and components...'
    $failures = New-Object System.Collections.Generic.List[string]

    # --- Operating system ---
    $isWindows = $true
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $isWindows = [bool]$IsWindows
    }
    else {
        $isWindows = ($env:OS -eq 'Windows_NT')
    }
    Write-CheckResult -Name 'Windows operating system' -Ok $isWindows -Detail $env:OS
    if (-not $isWindows) {
        $failures.Add('This installer only supports Windows.')
    }

    $osCaption = $null
    try {
        $osCaption = (Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption
    }
    catch {
        $cimError = Format-ErrorDetails -ErrorRecord $_ -Context 'Get-CimInstance Win32_OperatingSystem failed'
        try {
            $osCaption = (Get-WmiObject -Class Win32_OperatingSystem -ErrorAction Stop).Caption
            $osCaption = "$osCaption (via WMI fallback; CIM error logged at -Verbose)"
            Write-Verbose -Message $cimError
        }
        catch {
            $osCaption = 'Unknown Windows edition'
            Write-CheckResult -Name 'OS caption lookup' -Ok $false -Detail (
                "CIM and WMI both failed.`r`nCIM:`r`n{0}`r`nWMI:`r`n{1}" -f `
                    $cimError, (Format-ErrorDetails -ErrorRecord $_ -Context 'Get-WmiObject Win32_OperatingSystem failed'))
        }
    }
    $isWin10OrLater = $false
    $osVersionText = 'unavailable'
    try {
        $osVersion = [Environment]::OSVersion.Version
        $osVersionText = $osVersion.ToString()
        $isWin10OrLater = ($osVersion.Major -ge 10)
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context 'Reading Environment.OSVersion failed')
        $isWin10OrLater = $false
    }
    Write-CheckResult -Name 'Windows 10/11 (build 10+)' -Ok $isWin10OrLater -Detail ("{0}; Version={1}" -f $osCaption, $osVersionText)
    if (-not $isWin10OrLater) {
        $failures.Add(("Windows 10 or later is required. Detected: {0}; Version={1}" -f $osCaption, $osVersionText))
    }

    # --- Elevation ---
    $elevated = Test-IsAdministrator
    Write-CheckResult -Name 'Administrator elevation' -Ok $elevated
    if (-not $elevated) {
        $failures.Add('Re-run this script from an elevated PowerShell (Run as administrator).')
    }

    # --- Current PowerShell host ---
    $psOk = $PSVersionTable.PSVersion -ge [version]'5.1'
    Write-CheckResult -Name 'PowerShell 5.1+' -Ok $psOk -Detail ("host {0} {1}" -f $PSVersionTable.PSEdition, $PSVersionTable.PSVersion)
    if (-not $psOk) {
        $failures.Add('PowerShell 5.1 or later is required to run the installer.')
    }

    # --- Windows PowerShell (used by the scheduled task) ---
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $wpsOk = Test-Path -LiteralPath $windowsPowerShell
    Write-CheckResult -Name 'Windows PowerShell (powershell.exe)' -Ok $wpsOk -Detail $windowsPowerShell
    if (-not $wpsOk) {
        $failures.Add("Windows PowerShell not found at '$windowsPowerShell' (required by the startup task).")
    }

    # --- .NET Framework types used for ACL + Add-Type ---
    $aclTypeOk = $false
    $aclDetail = ''
    try {
        $null = [System.Security.AccessControl.FileSystemAccessRule]
        $null = [System.Security.AccessControl.FileSystemRights]
        $aclTypeOk = $true
        $aclDetail = 'System.Security.AccessControl types loaded'
    }
    catch {
        $aclDetail = Format-ErrorDetails -ErrorRecord $_ -Context 'Loading .NET ACL types failed'
        $aclTypeOk = $false
    }
    Write-CheckResult -Name '.NET FileSystemAccessRule (ACL APIs)' -Ok $aclTypeOk -Detail $aclDetail
    if (-not $aclTypeOk) {
        $failures.Add(".NET ACL types are unavailable; cannot protect the log/config directories.`r`n$aclDetail")
    }

    # --- Terminal Services API library ---
    $wtsPath = Join-Path $env:SystemRoot 'System32\wtsapi32.dll'
    $wtsOk = Test-Path -LiteralPath $wtsPath
    Write-CheckResult -Name 'Terminal Services library (wtsapi32.dll)' -Ok $wtsOk -Detail $wtsPath
    if (-not $wtsOk) {
        $failures.Add('wtsapi32.dll is missing; session lock detection cannot work.')
    }

    # --- ScheduledTasks module / cmdlets ---
    $schedModuleOk = $false
    $schedDetail = ''
    try {
        Import-Module ScheduledTasks -ErrorAction Stop
        $schedModuleOk = $true
        $mod = Get-Module ScheduledTasks
        $schedDetail = ("ModulePath={0}; Version={1}" -f $mod.Path, $mod.Version)
    }
    catch {
        $schedDetail = Format-ErrorDetails -ErrorRecord $_ -Context 'Import-Module ScheduledTasks failed'
        $schedModuleOk = $false
    }
    Write-CheckResult -Name 'ScheduledTasks PowerShell module' -Ok $schedModuleOk -Detail $schedDetail
    if (-not $schedModuleOk) {
        $failures.Add("ScheduledTasks module could not be imported.`r`n$schedDetail")
    }

    $requiredCmdlets = @(
        'Register-ScheduledTask',
        'New-ScheduledTaskAction',
        'New-ScheduledTaskTrigger',
        'New-ScheduledTaskSettingsSet',
        'New-ScheduledTaskPrincipal',
        'Start-ScheduledTask',
        'Get-Acl',
        'Set-Acl',
        'ConvertFrom-Json',
        'ConvertTo-Json'
    )
    $missingCmdlets = @()
    foreach ($cmd in $requiredCmdlets) {
        if (-not (Get-Command $cmd -ErrorAction SilentlyContinue)) {
            $missingCmdlets += $cmd
        }
    }
    $cmdletsOk = ($missingCmdlets.Count -eq 0)
    Write-CheckResult -Name 'Required PowerShell cmdlets' -Ok $cmdletsOk -Detail $(
        if ($cmdletsOk) { 'all present' } else { 'missing: ' + ($missingCmdlets -join ', ') }
    )
    if (-not $cmdletsOk) {
        $failures.Add('Missing cmdlets: ' + ($missingCmdlets -join ', '))
    }

    # --- Project files ---
    $requiredFiles = @{
        'Monitor script'         = $MonitorScript
        'Config template'        = $TemplateConfigPath
        'SessionQuery.cs'        = $CsPath
        'Common-Error.ps1'       = (Join-Path $RepoRoot 'src\Common-Error.ps1')
        'Update-Check.ps1'       = (Join-Path $RepoRoot 'src\Update-Check.ps1')
        'Scp-OnLock.ps1'         = (Join-Path $RepoRoot 'src\Scp-OnLock.ps1')
        'LockSignalWatcher.ps1'  = (Join-Path $RepoRoot 'src\LockSignalWatcher.ps1')
    }
    foreach ($entry in $requiredFiles.GetEnumerator()) {
        $exists = Test-Path -LiteralPath $entry.Value
        Write-CheckResult -Name $entry.Key -Ok $exists -Detail $entry.Value
        if (-not $exists) {
            $failures.Add("Required file missing: $($entry.Value)")
        }
    }

    # --- Config content (parsed before Git so UpdateEnabled can skip Git install) ---
    # AdminUsername / TargetUsername come from script parameters (required).
    $raw = $null
    $configOk = $false
    $updateEnabled = $false
    $administratorProfile = Get-ProfilePathForAccount -AccountName $AdminUsername

    $adminOk = -not [string]::IsNullOrWhiteSpace($AdminUsername)
    Write-CheckResult -Name 'AdminUsername (install owner)' -Ok $adminOk -Detail $(
        if ($adminOk) { '{0} -> {1}' -f $AdminUsername, $administratorProfile } else { 'empty' }
    )
    if (-not $adminOk) {
        $failures.Add('AdminUsername is required (administrative account for install/config/logs).')
    }

    $targetOk = -not [string]::IsNullOrWhiteSpace($TargetUsername)
    Write-CheckResult -Name 'TargetUsername (measured user)' -Ok $targetOk -Detail $(
        if ($targetOk) { $TargetUsername } else { 'empty' }
    )
    if (-not $targetOk) {
        $failures.Add('TargetUsername is required (account whose unlocked time will be measured).')
    }
    $configOk = $adminOk -and $targetOk

    if (Test-Path -LiteralPath $TemplateConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            # Parameter values win over template placeholders.
            $raw.TargetUsername = $TargetUsername
            $raw.AdministratorProfile = $administratorProfile
            if ($null -ne $raw.UpdateEnabled) {
                $updateEnabled = [bool]$raw.UpdateEnabled
            }
            Write-CheckResult -Name 'Config UpdateEnabled' -Ok $true -Detail $(
                if ($updateEnabled) { 'true (Git required)' } else { 'false (Git optional / skipped)' }
            )
        }
        catch {
            $parseDetails = Format-ErrorDetails -ErrorRecord $_ -Context ("Parsing '{0}'" -f $TemplateConfigPath)
            Write-CheckResult -Name 'Config JSON parse' -Ok $false -Detail $parseDetails
            $failures.Add("config\config.json is not valid JSON.`r`n$parseDetails")
            $configOk = $false
        }
    }
    else {
        $failures.Add("Config template missing: $TemplateConfigPath")
        $configOk = $false
    }

    if ($adminOk) {
        $adminExists = Test-AccountExists -UserName $AdminUsername -ProfilePath $administratorProfile
        Write-CheckResult -Name ("Admin account exists '{0}'" -f $AdminUsername) -Ok $adminExists -Detail $(
            if ($adminExists) { $administratorProfile } else { 'NTAccount/ProfileList failed' }
        )
        if (-not $adminExists) {
            $failures.Add("AdminUsername '$AdminUsername' was not found. Use DOMAIN\user, UPN, local SAM, or a profile path under Users\.")
            $configOk = $false
        }
    }

    # --- git + trusted UpdateRepoUrl (only when self-update is enabled) ---
    if ($updateEnabled) {
        $repoUrl = 'https://github.com/ldorau/log-logged-in-time.git'
        if ($raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.UpdateRepoUrl)) {
            $repoUrl = [string]$raw.UpdateRepoUrl
        }
        $repoTrusted = $false
        try {
            $uri = [Uri]$repoUrl
            $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
            $repoTrusted = (
                $uri.IsAbsoluteUri -and
                $uri.Scheme -eq 'https' -and
                [string]::Equals($uri.Host, 'github.com', [StringComparison]::OrdinalIgnoreCase) -and
                (@('/ldorau/log-logged-in-time', '/ldorau/log-logged-in-time.git') -contains $path)
            )
        }
        catch {
            $repoTrusted = $false
        }
        Write-CheckResult -Name 'UpdateRepoUrl allowlist' -Ok $repoTrusted -Detail $repoUrl
        if (-not $repoTrusted) {
            $failures.Add(("UpdateRepoUrl must be https://github.com/ldorau/log-logged-in-time(.git). Got: {0}" -f $repoUrl))
        }

        $gitPath = Find-GitExecutable
        if (-not $gitPath) {
            try {
                $gitPath = Install-GitForWindows
                Write-CheckResult -Name 'Git (git.exe) for self-update' -Ok $true -Detail ("installed: {0}" -f $gitPath)
            }
            catch {
                $gitDetails = Format-ErrorDetails -ErrorRecord $_ -Context 'Automatic Git for Windows install failed'
                Write-CheckResult -Name 'Git (git.exe) for self-update' -Ok $false -Detail $gitDetails
                $failures.Add(("git.exe is required when UpdateEnabled=true. Automatic install failed.`r`n{0}" -f $gitDetails))
            }
        }
        else {
            Write-CheckResult -Name 'Git (git.exe) for self-update' -Ok $true -Detail $gitPath
        }
    }
    else {
        $gitPath = Find-GitExecutable
        Write-CheckResult -Name 'Git (git.exe) for self-update' -Ok $true -Detail $(
            if ($gitPath) { "present (not required): $gitPath" } else { 'skipped (UpdateEnabled=false)' }
        )
    }

    # --- OpenSSH scp (only when SCP-on-lock is enabled) ---
    $scpOnLockEnabled = $false
    if ($raw -and $null -ne $raw.ScpOnLockEnabled) {
        $scpOnLockEnabled = [bool]$raw.ScpOnLockEnabled
    }
    if ($scpOnLockEnabled) {
        $scpPath = Find-ScpExecutable
        if (-not $scpPath) {
            try {
                $scpPath = Install-OpenSshClient
                Write-CheckResult -Name 'OpenSSH scp.exe (SCP on lock)' -Ok $true -Detail ("installed: {0}" -f $scpPath)
            }
            catch {
                $scpDetails = Format-ErrorDetails -ErrorRecord $_ -Context 'Automatic OpenSSH Client install failed'
                Write-CheckResult -Name 'OpenSSH scp.exe (SCP on lock)' -Ok $false -Detail $scpDetails
                $failures.Add(("scp.exe is required when ScpOnLockEnabled=true. Automatic OpenSSH Client install failed.`r`n{0}" -f $scpDetails))
            }
        }
        else {
            Write-CheckResult -Name 'OpenSSH scp.exe (SCP on lock)' -Ok $true -Detail $scpPath
        }

        $scpHostOk = $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.ScpHost)
        $scpUserOk = $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.ScpUser)
        $scpDirOk = $raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.ScpRemoteDirectory)
        Write-CheckResult -Name 'SCP remote host/user/directory' -Ok ($scpHostOk -and $scpUserOk -and $scpDirOk) -Detail $(
            if ($scpHostOk -and $scpUserOk -and $scpDirOk) {
                '{0}@{1}:{2}' -f $raw.ScpUser, $raw.ScpHost, $raw.ScpRemoteDirectory
            }
            else {
                'set ScpHost, ScpUser, and ScpRemoteDirectory in config\config.json'
            }
        )
        if (-not ($scpHostOk -and $scpUserOk -and $scpDirOk)) {
            $failures.Add('ScpOnLockEnabled=true requires ScpHost, ScpUser, and ScpRemoteDirectory in config\config.json.')
        }

        $identityPath = $null
        if ($raw -and -not [string]::IsNullOrWhiteSpace([string]$raw.ScpIdentityFile)) {
            $identityPath = [string]$raw.ScpIdentityFile
        }
        else {
            $identityPath = Join-Path $administratorProfile 'LoginTimeLogger\ssh\id_ed25519'
        }
        $identityOk = Test-Path -LiteralPath $identityPath
        Write-CheckResult -Name 'SCP identity file (private key)' -Ok $identityOk -Detail $identityPath
        if (-not $identityOk) {
            $failures.Add(("ScpOnLockEnabled=true requires an SSH private key at '{0}' (or set ScpIdentityFile)." -f $identityPath))
        }
    }
    else {
        Write-CheckResult -Name 'OpenSSH scp.exe (SCP on lock)' -Ok $true -Detail 'skipped (ScpOnLockEnabled=false)'
    }

    if ($targetOk) {
        $targetProfileGuess = Join-Path $env:SystemDrive ('Users\{0}' -f (Get-AccountSamLeaf -UserName $TargetUsername))
        $userExists = Test-AccountExists -UserName $TargetUsername -ProfilePath $targetProfileGuess
        Write-CheckResult -Name ("Measured account exists '{0}'" -f $TargetUsername) -Ok $userExists
        if (-not $userExists) {
            $failures.Add("TargetUsername '$TargetUsername' was not found. Use DOMAIN\user, UPN, local SAM, or ensure the profile exists under Users\.")
            $configOk = $false
        }
    }

    # --- Program Files writable ---
    $programFilesOk = $false
    $pfDetail = $env:ProgramFiles
    try {
        if (-not (Test-Path -LiteralPath $env:ProgramFiles)) {
            throw "Program Files path missing: $env:ProgramFiles"
        }
        $probe = Join-Path $env:ProgramFiles ('LoginTimeLogger.write-test-' + [guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $probe -Force | Out-Null
        Remove-Item -LiteralPath $probe -Force
        $programFilesOk = $true
        $pfDetail = "writable: $env:ProgramFiles"
    }
    catch {
        $pfDetail = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Program Files write probe failed; ProgramFiles='{0}'" -f $env:ProgramFiles)
    }
    Write-CheckResult -Name 'Program Files write access' -Ok $programFilesOk -Detail $pfDetail
    if (-not $programFilesOk) {
        $failures.Add("Cannot write under Program Files; install cannot copy monitor scripts.`r`n$pfDetail")
    }

    # --- Compile + exercise SessionQuery under Windows PowerShell (task runtime) ---
    $compileOk = $false
    $compileDetail = ''
    if ($wpsOk -and (Test-Path -LiteralPath $CsPath)) {
        $probeScript = @"
`$ErrorActionPreference = 'Stop'
`$src = Get-Content -LiteralPath '$($CsPath.Replace("'", "''"))' -Raw -Encoding UTF8
Add-Type -TypeDefinition `$src -Language CSharp
`$sessions = [SessionQuery]::GetSessions()
Write-Output ('compiled; sessions=' + `$sessions.Count)
"@
        try {
            # Hidden Start-Process avoids a flashing console from nested powershell.exe.
            $stdoutFile = Join-Path $env:TEMP ('LoginTimeLogger-compile-out-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            $stderrFile = Join-Path $env:TEMP ('LoginTimeLogger-compile-err-{0}.txt' -f [guid]::NewGuid().ToString('N'))
            $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
            $probeArgLine = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -EncodedCommand {0}' -f $encoded
            try {
                $proc = Start-Process -FilePath $windowsPowerShell `
                    -ArgumentList $probeArgLine `
                    -RedirectStandardOutput $stdoutFile `
                    -RedirectStandardError $stderrFile `
                    -WindowStyle Hidden `
                    -PassThru `
                    -Wait
                $exitCode = $proc.ExitCode
                $outText = ''
                $errText = ''
                if (Test-Path -LiteralPath $stdoutFile) {
                    $outText = (Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
                }
                if (Test-Path -LiteralPath $stderrFile) {
                    $errText = (Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
                }
                $text = (@($outText, $errText) -join [Environment]::NewLine).Trim()
                if ($exitCode -eq 0 -and $text -match 'compiled; sessions=') {
                    $compileOk = $true
                    $compileDetail = ($text -split '\r?\n' | Where-Object { $_ -match 'compiled; sessions=' } | Select-Object -First 1)
                }
                else {
                    $compileDetail = "exit=$exitCode; $text"
                }
            }
            finally {
                Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
            }
        }
        catch {
            $compileDetail = Format-ErrorDetails -ErrorRecord $_ -Context (
                "SessionQuery compile probe threw; powershell='{0}'; cs='{1}'" -f $windowsPowerShell, $CsPath)
        }
    }
    else {
        $compileDetail = ("skipped (powershellOk={0}; csExists={1}; powershell='{2}'; cs='{3}')" -f `
                $wpsOk, (Test-Path -LiteralPath $CsPath), $windowsPowerShell, $CsPath)
    }
    Write-CheckResult -Name 'SessionQuery.cs compiles in Windows PowerShell' -Ok $compileOk -Detail $compileDetail
    if (-not $compileOk) {
        $failures.Add("SessionQuery.cs failed to compile/run under Windows PowerShell (Add-Type / .NET C# compiler).`r`n$compileDetail")
    }

    # Shared error helper used by installed monitor
    $commonError = Join-Path $RepoRoot 'src\Common-Error.ps1'
    $commonOk = Test-Path -LiteralPath $commonError
    Write-CheckResult -Name 'Common-Error.ps1 helper' -Ok $commonOk -Detail $commonError
    if (-not $commonOk) {
        $failures.Add("Required helper missing: $commonError")
    }

    Write-Host ''
    if ($failures.Count -gt 0) {
        $summaryLines = New-Object System.Collections.Generic.List[string]
        $summaryLines.Add('Prerequisite check failed:')
        $i = 1
        foreach ($item in $failures) {
            $summaryLines.Add(("  [{0}] {1}" -f $i, $item))
            $i++
        }
        $summaryLines.Add('')
        $summaryLines.Add("Install aborted: $($failures.Count) prerequisite check(s) failed.")
        $summaryLines.Add("RepoRoot: $RepoRoot")
        $summaryLines.Add("TemplateConfig: $TemplateConfigPath")
        $summary = $summaryLines -join [Environment]::NewLine
        $null = Write-ErrorMessage -Message $summary -Level ERROR -Source 'Install.Prerequisites'
        throw $summary
    }

    Write-Host 'All prerequisite checks passed.' -ForegroundColor Green
    Write-Host ''
    return $raw
}

function Write-LockSignalHiddenLauncher {
    <#
      Writes a tiny VBS that starts LockSignalWatcher with WScript.Shell.Run style 0
      (no console window). Interactive scheduled tasks that launch powershell.exe
      directly often flash a visible PowerShell window during Install -StartNow.
    #>
    param(
        [Parameter(Mandatory)][string]$LauncherPath,
        [Parameter(Mandatory)][string]$PowerShellExe,
        [Parameter(Mandatory)][string]$WatcherScript,
        [Parameter(Mandatory)][string]$TargetUsername,
        [Parameter(Mandatory)][string]$SignalPath,
        [int]$HeartbeatSeconds = 15
    )

    $dir = Split-Path -Parent $LauncherPath
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    function Escape-Vbs {
        param([string]$Value)
        return (($Value -replace '"', '""'))
    }

    $psCmd = '"{0}" -NoProfile -NoLogo -WindowStyle Hidden -ExecutionPolicy Bypass -STA -File "{1}" -TargetUsername "{2}" -SignalPath "{3}" -HeartbeatSeconds {4}' -f `
        $PowerShellExe, $WatcherScript, $TargetUsername, $SignalPath, $HeartbeatSeconds
    $psCmdVbs = Escape-Vbs -Value $psCmd

    # Wait=True so the scheduled task stays Running while the watcher lives (wscript is the task host).
    $vbs = @(
        "' Auto-generated by Install.ps1 - do not edit."
        'Option Explicit'
        'Dim sh, cmd'
        'Set sh = CreateObject("WScript.Shell")'
        ('cmd = "{0}"' -f $psCmdVbs)
        "' 0 = hidden window; True = wait so Task Scheduler tracks the watcher lifetime."
        'sh.Run cmd, 0, True'
    ) -join "`r`n"
    Set-Content -LiteralPath $LauncherPath -Value $vbs -Encoding ASCII
}

function Set-ProtectedDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$DeniedUsername,
        [Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$AllowedAdminSid,
        [string]$AdministratorProfile = ''
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    # Allow the configured admin profile account + SYSTEM only.
    # Do not require BUILTIN\Administrators (missing/unusable on some Home setups).
    $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')

    $acl = Get-Acl -LiteralPath $Directory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        $null = $acl.RemoveAccessRule($rule)
    }
    $acl.AddAccessRule((New-SidFileSystemAccessRule `
                -Sid $AllowedAdminSid `
                -Rights FullControl `
                -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                -PropagationFlags None `
                -AccessControlType Allow))
    $acl.AddAccessRule((New-SidFileSystemAccessRule `
                -Sid $sidSystem `
                -Rights FullControl `
                -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                -PropagationFlags None `
                -AccessControlType Allow))

    $deniedSid = Resolve-AccountSid -UserName $DeniedUsername -ProfilePath $AdministratorProfile
    if ($deniedSid) {
        if ($deniedSid.Value -eq $AllowedAdminSid.Value) {
            # Allowed for testing when AdminUsername == TargetUsername.
            Write-Host ("  Note: measured user equals admin account; skipping Deny ACE on '{0}' (OK for testing)." -f $Directory) -ForegroundColor Yellow
        }
        else {
            try {
                $acl.AddAccessRule((New-SidFileSystemAccessRule `
                            -Sid $deniedSid `
                            -Rights FullControl `
                            -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                            -PropagationFlags None `
                            -AccessControlType Deny))
            }
            catch {
                $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Install' -Context (
                    "Could not add Deny ACE; user='{0}'; sid='{1}'; directory='{2}'" -f `
                        $DeniedUsername, $deniedSid.Value, $Directory)
            }
        }
    }
    else {
        $null = Write-ErrorMessage -Level WARN -Source 'Install' -Message (
            "Could not resolve '{0}' to a SID for Deny ACE on '{1}'. Directory is still admin-profile + SYSTEM only." -f `
                $DeniedUsername, $Directory)
    }

    try {
        Set-Acl -LiteralPath $Directory -AclObject $acl
        # Re-apply to existing children (e.g. errors.log created during prerequisite checks).
        Get-ChildItem -LiteralPath $Directory -Force -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                Set-Acl -LiteralPath $_.FullName -AclObject $acl
            }
            catch {
                $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Install' -Context (
                    "Set-Acl failed for child '{0}'" -f $_.FullName)
            }
        }
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Set-Acl failed; directory='{0}'" -f $Directory)
        throw (New-Object System.Exception($details, $_.Exception))
    }
}

try {
    $currentAccount = (& whoami 2>$null | Select-Object -First 1)
    if ([string]::IsNullOrWhiteSpace($currentAccount)) {
        $currentAccount = '{0}\{1}' -f $env:USERDOMAIN, $env:USERNAME
    }
    $currentUpn = $null
    try {
        $upnOut = & whoami /upn 2>$null
        if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace(($upnOut | Out-String).Trim())) {
            $currentUpn = (($upnOut | Out-String).Trim() -split '\r?\n')[0].Trim()
        }
    }
    catch { }
    if ([string]::IsNullOrWhiteSpace($currentUpn)) {
        $currentUpn = '(none)'
    }

    Write-Host 'Current machine / account context:' -ForegroundColor Cyan
    Write-Host ("  COMPUTERNAME : {0}" -f $env:COMPUTERNAME)
    Write-Host ("  USERDOMAIN   : {0}" -f $env:USERDOMAIN)
    Write-Host ("  Account      : {0}" -f $currentAccount.Trim())
    Write-Host ("  UPN          : {0}" -f $currentUpn)
    Write-Host ("  AdminUsername: {0}" -f $AdminUsername)
    Write-Host ("  TargetUsername: {0}" -f $TargetUsername)
    Write-Host ''

    $monitorScript = Join-Path $repoRoot 'src\LoginTimeLogger.ps1'
    $templateConfigPath = Join-Path $repoRoot 'config\config.json'
    $csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
    $commonErrorSrc = Join-Path $repoRoot 'src\Common-Error.ps1'
    $updateCheckSrc = Join-Path $repoRoot 'src\Update-Check.ps1'
    $scpOnLockSrc = Join-Path $repoRoot 'src\Scp-OnLock.ps1'

    $raw = Test-InstallPrerequisites `
        -RepoRoot $repoRoot `
        -MonitorScript $monitorScript `
        -TemplateConfigPath $templateConfigPath `
        -CsPath $csPath `
        -AdminUsername $AdminUsername `
        -TargetUsername $TargetUsername

    $targetUsername = [string]$TargetUsername
    $administratorProfile = Get-ProfilePathForAccount -AccountName $AdminUsername

    $adminAccountName = if (Test-LooksLikeFilePath -Value $AdminUsername) {
        Get-AccountNameFromProfilePath -ProfilePath $administratorProfile
    }
    else {
        Get-AccountSamLeaf -UserName $AdminUsername
    }
    $allowedAdminSid = Resolve-AdministratorAccountSid `
        -AdministratorProfile $administratorProfile `
        -AdminUsername $AdminUsername
    if (-not $allowedAdminSid) {
        throw ("Could not resolve AdminUsername '{0}' (profile '{1}') to a SID for ACLs. Tried NTAccount and ProfileList." -f `
                $AdminUsername, $administratorProfile)
    }
    Write-Host ("Administrator account for ACLs: {0} (profile {1}; SID {2})" -f `
            $adminAccountName, $administratorProfile, $allowedAdminSid.Value)
    $targetSid = Resolve-AccountSid -UserName $targetUsername -ProfilePath $administratorProfile
    if ($targetSid -and ($targetSid.Value -eq $allowedAdminSid.Value)) {
        Write-Host 'Note: AdminUsername and TargetUsername resolve to the same account (supported for testing).' -ForegroundColor Yellow
    }

    $pollSeconds = 5
    if ($null -ne $raw.PollIntervalSeconds -and [int]$raw.PollIntervalSeconds -gt 0) {
        $pollSeconds = [int]$raw.PollIntervalSeconds
    }

    $updateEnabled = $false
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
    $updateClonePath = Join-Path $administratorProfile 'LoginTimeLogger\repo'
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.UpdateClonePath)) {
        $updateClonePath = [string]$raw.UpdateClonePath
    }

    $scpOnLockEnabledRuntime = $false
    if ($null -ne $raw.ScpOnLockEnabled) {
        $scpOnLockEnabledRuntime = [bool]$raw.ScpOnLockEnabled
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
    elseif ($scpOnLockEnabledRuntime) {
        $scpIdentityFile = Join-Path $administratorProfile 'LoginTimeLogger\ssh\id_ed25519'
    }
    $scpKnownHostsFile = ''
    if (-not [string]::IsNullOrWhiteSpace([string]$raw.ScpKnownHostsFile)) {
        $scpKnownHostsFile = [string]$raw.ScpKnownHostsFile
    }
    elseif ($scpOnLockEnabledRuntime) {
        $scpKnownHostsFile = Join-Path $administratorProfile 'LoginTimeLogger\ssh\known_hosts'
    }

    $null = Initialize-ErrorLog -AdministratorProfile $administratorProfile
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    if (-not (Test-Path -LiteralPath $administratorProfile)) {
        $null = Write-ErrorMessage -Level WARN -Source 'Install' -Message @"
Administrator profile not found at '$administratorProfile' (from AdminUsername '$AdminUsername').
Folders will still be created. Confirm the account has a local profile under Users\.
SystemDrive: $env:SystemDrive
"@
    }

    $adminAppDirectory = Join-Path $administratorProfile 'LoginTimeLogger'
    $runtimeConfigPath = Join-Path $adminAppDirectory 'config.json'

    $logDirectory = [string]$raw.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    }

    $lockSignalPath = Join-Path $env:ProgramData 'LoginTimeLogger\lock-signal.json'
    $lockSignalTaskName = 'LoginTimeLoggerLockSignal'

    $config = [ordered]@{
        AdminUsername        = [string]$AdminUsername
        TargetUsername       = $targetUsername
        AdministratorProfile = $administratorProfile
        LogDirectory         = $logDirectory
        PollIntervalSeconds  = $pollSeconds
        LockSignalPath       = $lockSignalPath
        UpdateEnabled        = $updateEnabled
        UpdateRepoUrl        = $updateRepoUrl
        UpdateBranch         = $updateBranch
        UpdateClonePath      = $updateClonePath
        ScpOnLockEnabled     = $scpOnLockEnabledRuntime
        ScpHost              = $scpHost
        ScpUser              = $scpUser
        ScpRemoteDirectory   = $scpRemoteDirectory
        ScpPort              = $scpPort
        ScpIdentityFile      = $scpIdentityFile
        ScpKnownHostsFile    = $scpKnownHostsFile
    }
    $configJson = $config | ConvertTo-Json -Depth 4

    # Write runtime config only; leave the project template config.json untouched.
    try {
        Set-ProtectedDirectory -Directory $adminAppDirectory -DeniedUsername $targetUsername `
            -AllowedAdminSid $allowedAdminSid -AdministratorProfile $administratorProfile
        $configJson | Set-Content -LiteralPath $runtimeConfigPath -Encoding UTF8
        Set-ProtectedDirectory -Directory $logDirectory -DeniedUsername $targetUsername `
            -AllowedAdminSid $allowedAdminSid -AdministratorProfile $administratorProfile
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Creating protected Administrator folders/config failed; adminApp='{0}'; runtimeConfig='{1}'; logDir='{2}'" -f `
                $adminAppDirectory, $runtimeConfigPath, $logDirectory)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    # SessionSwitch signal dir: target user must write; SYSTEM/admin read (not the ACL-denied log folder).
    try {
        $lockSignalDir = Split-Path -Parent $lockSignalPath
        if (-not (Test-Path -LiteralPath $lockSignalDir)) {
            New-Item -ItemType Directory -Path $lockSignalDir -Force | Out-Null
        }
        $signalAcl = Get-Acl -LiteralPath $lockSignalDir
        $signalAcl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($signalAcl.Access)) {
            $null = $signalAcl.RemoveAccessRule($rule)
        }
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $sidAdmins = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-544')
        $signalAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $sidSystem `
                    -Rights FullControl `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        $signalAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $sidAdmins `
                    -Rights FullControl `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        $signalAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $allowedAdminSid `
                    -Rights FullControl `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        if ($targetSid) {
            $signalAcl.AddAccessRule((New-SidFileSystemAccessRule `
                        -Sid $targetSid `
                        -Rights Modify `
                        -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                        -PropagationFlags None `
                        -AccessControlType Allow))
        }
        Set-Acl -LiteralPath $lockSignalDir -AclObject $signalAcl
        Write-Host ("Lock signal directory: {0}" -f $lockSignalDir)
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Creating lock-signal directory/ACL failed; path='{0}'" -f $lockSignalPath)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    # Prefer Security 4800/4801 when policy allows (may be overridden by domain GPO).
    try {
        $auditOut = & auditpol.exe /set /subcategory:'{0CCE921C-69AE-11D9-BED3-505054503030}' /success:enable 2>&1
        $auditText = ($auditOut | Out-String).Trim()
        if ($LASTEXITCODE -eq 0) {
            Write-Host 'Enabled Success audit for Other Logon/Logoff Events (Security 4800/4801).'
        }
        else {
            Write-Warning ("Could not enable Other Logon/Logoff audit (exit={0}): {1}. LockSignalWatcher remains the primary Win+L signal." -f `
                    $LASTEXITCODE, $auditText)
        }
    }
    catch {
        Write-Warning ("auditpol failed: {0}. LockSignalWatcher remains the primary Win+L signal." -f $_.Exception.Message)
    }

    $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    $installSrc = Join-Path $installRoot 'src'
    $lockSignalWatcherSrc = Join-Path $repoRoot 'src\LockSignalWatcher.ps1'

    try {
        New-Item -ItemType Directory -Path $installSrc -Force | Out-Null
        Copy-Item -LiteralPath $monitorScript -Destination (Join-Path $installSrc 'LoginTimeLogger.ps1') -Force
        Copy-Item -LiteralPath $csPath -Destination (Join-Path $installSrc 'SessionQuery.cs') -Force
        Copy-Item -LiteralPath $commonErrorSrc -Destination (Join-Path $installSrc 'Common-Error.ps1') -Force
        Copy-Item -LiteralPath $updateCheckSrc -Destination (Join-Path $installSrc 'Update-Check.ps1') -Force
        Copy-Item -LiteralPath $scpOnLockSrc -Destination (Join-Path $installSrc 'Scp-OnLock.ps1') -Force
        Copy-Item -LiteralPath $lockSignalWatcherSrc -Destination (Join-Path $installSrc 'LockSignalWatcher.ps1') -Force
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Copying monitor files to Program Files failed; installRoot='{0}'" -f $installRoot)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    # Record currently installed commit hash for daily update comparisons.
    $installedCommit = $null
    try {
        $gitExe = Find-GitExecutable
        if ($gitExe) {
            $installedCommit = (& $gitExe -C $repoRoot rev-parse HEAD 2>$null)
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace("$installedCommit")) {
                $installedCommit = ("$installedCommit").Trim().ToLowerInvariant()
                Set-Content -LiteralPath (Join-Path $installRoot 'installed-commit.txt') -Value $installedCommit -Encoding ASCII
                Write-Host "Installed commit: $installedCommit"
            }
        }
    }
    catch {
        Write-Warning ("Could not record installed commit hash: {0}" -f $_.Exception.Message)
    }

    try {
        $installedAcl = Get-Acl -LiteralPath $installRoot
        $installedAcl.SetAccessRuleProtection($true, $false)
        foreach ($rule in @($installedAcl.Access)) {
            $null = $installedAcl.RemoveAccessRule($rule)
        }
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-18')
        $sidUsers = New-Object System.Security.Principal.SecurityIdentifier('S-1-5-32-545')
        $installedAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $allowedAdminSid `
                    -Rights FullControl `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        $installedAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $sidSystem `
                    -Rights FullControl `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        $installedAcl.AddAccessRule((New-SidFileSystemAccessRule `
                    -Sid $sidUsers `
                    -Rights ReadAndExecute `
                    -InheritanceFlags 'ContainerInherit,ObjectInherit' `
                    -PropagationFlags None `
                    -AccessControlType Allow))
        Set-Acl -LiteralPath $installRoot -AclObject $installedAcl
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Setting ACL on install root failed; installRoot='{0}'" -f $installRoot)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    $installedScript = Join-Path $installSrc 'LoginTimeLogger.ps1'
    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argument = '-NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $installedScript, $runtimeConfigPath

    try {
        $action = New-ScheduledTaskAction -Execute $windowsPowerShell -Argument $argument
        $trigger = New-ScheduledTaskTrigger -AtStartup
        $settings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 3 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew `
            -Hidden

        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Register-ScheduledTask failed; task='{0}'; execute='{1}'; args='{2}'" -f `
                $TaskName, $windowsPowerShell, $argument)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    # User-context SessionSwitch watcher (primary Win+L signal when WTS/Desktop lie).
    # Launch via wscript (hidden) - direct powershell.exe Interactive tasks flash a console.
    $installedLockWatcher = Join-Path $installSrc 'LockSignalWatcher.ps1'
    $lockLauncherVbs = Join-Path $installSrc 'Start-LockSignalWatcher.vbs'
    $wscriptExe = Join-Path $env:SystemRoot 'System32\wscript.exe'
    Write-LockSignalHiddenLauncher `
        -LauncherPath $lockLauncherVbs `
        -PowerShellExe $windowsPowerShell `
        -WatcherScript $installedLockWatcher `
        -TargetUsername $targetUsername `
        -SignalPath $lockSignalPath `
        -HeartbeatSeconds 15
    $lockWatcherArgs = '//B //Nologo "{0}"' -f $lockLauncherVbs
    try {
        $lockAction = New-ScheduledTaskAction -Execute $wscriptExe -Argument $lockWatcherArgs
        $lockTrigger = New-ScheduledTaskTrigger -AtLogOn -User $targetUsername
        # RestartInterval minimum accepted by Task Scheduler is 1 minute (PT15S fails with 0x80041318).
        $lockSettings = New-ScheduledTaskSettingsSet `
            -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries `
            -StartWhenAvailable `
            -RestartCount 999 `
            -RestartInterval (New-TimeSpan -Minutes 1) `
            -ExecutionTimeLimit ([TimeSpan]::Zero) `
            -MultipleInstances IgnoreNew `
            -DontStopOnIdleEnd `
            -Hidden
        $lockPrincipal = New-ScheduledTaskPrincipal -UserId $targetUsername -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $lockSignalTaskName -Action $lockAction -Trigger $lockTrigger `
            -Settings $lockSettings -Principal $lockPrincipal -Force -ErrorAction Stop | Out-Null
        $registeredLock = Get-ScheduledTask -TaskName $lockSignalTaskName -ErrorAction Stop
        if (-not $registeredLock) {
            throw "Lock signal task '$lockSignalTaskName' was not present after Register-ScheduledTask."
        }
        Write-Host ("Installed scheduled task '{0}' (At logon as {1}, hidden wscript lock signal)." -f `
                $lockSignalTaskName, $targetUsername)
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Register-ScheduledTask failed for lock signal; task='{0}'; user='{1}'" -f `
                $lockSignalTaskName, $targetUsername)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    Write-Host "Installed scheduled task '$TaskName' (At startup, SYSTEM, Highest)."
    Write-Host "Monitor scripts: $installRoot"
    Write-Host "Runtime config:  $runtimeConfigPath"
    Write-Host "Log directory:   $logDirectory"
    Write-Host "Lock signal:     $lockSignalPath"
    Write-Host "Target username: $targetUsername"

    if ($StartNow) {
        try {
            Start-ScheduledTask -TaskName $TaskName
            Write-Host 'Task started.'
        }
        catch {
            $details = Format-ErrorDetails -ErrorRecord $_ -Context (
                "Start-ScheduledTask failed after successful registration; task='{0}'" -f $TaskName)
            throw (New-Object System.Exception($details, $_.Exception))
        }

        try {
            Start-ScheduledTask -TaskName $lockSignalTaskName -ErrorAction Stop
            Write-Host ("Lock signal task '{0}' started (needs interactive logon session)." -f $lockSignalTaskName)
        }
        catch {
            Write-Warning ("Could not start '{0}' now (user may need to log off/on): {1}" -f `
                    $lockSignalTaskName, $_.Exception.Message)
        }
    }
    else {
        Write-Host "Run: Start-ScheduledTask -TaskName '$TaskName'   (or reboot)"
        Write-Host "Lock signal starts at next logon of '$targetUsername' (task '$lockSignalTaskName')."
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Install.ps1 failed' -Source 'Install'
    throw
}
