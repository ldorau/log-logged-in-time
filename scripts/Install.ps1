#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Installs LoginTimeLogger to start at system boot with highest privileges.
.DESCRIPTION
  Reads settings from the repo template config\config.json, then stores the
  runtime config under the Administrator profile (ACL-protected). Creates a
  Scheduled Task that runs as SYSTEM at startup.
#>
[CmdletBinding()]
param(
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

function Test-AccountExists {
    <#
    .SYNOPSIS
      Returns true if TargetUsername resolves to a Windows account (local or domain).
      Accepts: user | DOMAIN\user | user@upn.domain
    #>
    param([Parameter(Mandatory)][string]$UserName)

    try {
        $ntAccount = New-Object System.Security.Principal.NTAccount($UserName)
        $sid = $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
        Write-Verbose -Message ("Resolved '{0}' -> SID {1}" -f $UserName, $sid.Value)
        return $true
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context (
                "NTAccount.Translate failed for '{0}'" -f $UserName))
    }

    # Local SAM fallback when only the short name was supplied.
    $sam = $UserName
    if ($sam -match '^(?<domain>[^\\]+)\\(?<user>.+)$') {
        $sam = $Matches['user']
    }
    elseif ($sam -match '^(?<user>[^@]+)@') {
        $sam = $Matches['user']
    }

    try {
        if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
            $null = Get-LocalUser -Name $sam -ErrorAction Stop
            return $true
        }
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context (
                "Get-LocalUser lookup failed for '{0}'" -f $sam))
    }

    try {
        $account = [ADSI]"WinNT://./$sam,user"
        $null = $account.Name
        return $true
    }
    catch {
        Write-Verbose -Message (Format-ErrorDetails -ErrorRecord $_ -Context (
                "ADSI WinNT user lookup failed for '{0}'" -f $sam))
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

function Test-InstallPrerequisites {
    param(
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string]$MonitorScript,
        [Parameter(Mandatory)][string]$TemplateConfigPath,
        [Parameter(Mandatory)][string]$CsPath
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
        'Monitor script'   = $MonitorScript
        'Config template'  = $TemplateConfigPath
        'SessionQuery.cs'  = $CsPath
        'Common-Error.ps1' = (Join-Path $RepoRoot 'src\Common-Error.ps1')
        'Update-Check.ps1' = (Join-Path $RepoRoot 'src\Update-Check.ps1')
    }
    foreach ($entry in $requiredFiles.GetEnumerator()) {
        $exists = Test-Path -LiteralPath $entry.Value
        Write-CheckResult -Name $entry.Key -Ok $exists -Detail $entry.Value
        if (-not $exists) {
            $failures.Add("Required file missing: $($entry.Value)")
        }
    }

    # --- Config content (parsed before Git so UpdateEnabled can skip Git install) ---
    $raw = $null
    $configOk = $false
    $targetUsername = $null
    $updateEnabled = $false
    if (Test-Path -LiteralPath $TemplateConfigPath) {
        try {
            $raw = Get-Content -LiteralPath $TemplateConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $targetUsername = [string]$raw.TargetUsername
            $configOk = -not [string]::IsNullOrWhiteSpace($targetUsername)
            if ($null -ne $raw.UpdateEnabled) {
                $updateEnabled = [bool]$raw.UpdateEnabled
            }
            Write-CheckResult -Name 'Config TargetUsername' -Ok $configOk -Detail $(
                if ($configOk) { $targetUsername } else { 'empty - set Windows logon name in config\config.json' }
            )
            if (-not $configOk) {
                $failures.Add('config\config.json has an empty TargetUsername. Set the Windows logon name, then retry.')
            }
            Write-CheckResult -Name 'Config UpdateEnabled' -Ok $true -Detail $(
                if ($updateEnabled) { 'true (Git required)' } else { 'false (Git optional / skipped)' }
            )
        }
        catch {
            $parseDetails = Format-ErrorDetails -ErrorRecord $_ -Context ("Parsing '{0}'" -f $TemplateConfigPath)
            Write-CheckResult -Name 'Config JSON parse' -Ok $false -Detail $parseDetails
            $failures.Add("config\config.json is not valid JSON.`r`n$parseDetails")
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

    if ($configOk) {
        $userExists = Test-AccountExists -UserName $targetUsername
        Write-CheckResult -Name ("Account exists (local or domain) '{0}'" -f $targetUsername) -Ok $userExists
        if (-not $userExists) {
            $failures.Add("Account '$targetUsername' was not found. Use local SAM, DOMAIN\user, or user@upn.domain in config\config.json.")
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
            $output = & $windowsPowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $probeScript 2>&1
            $exitCode = $LASTEXITCODE
            $text = ($output | Out-String).Trim()
            if ($exitCode -eq 0 -and $text -match 'compiled; sessions=') {
                $compileOk = $true
                $compileDetail = $text
            }
            else {
                $compileDetail = "exit=$exitCode; $text"
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

function Set-ProtectedDirectory {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$DeniedUsername
    )

    if (-not (Test-Path -LiteralPath $Directory)) {
        New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    }

    $acl = Get-Acl -LiteralPath $Directory
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($rule in @($acl.Access)) {
        $null = $acl.RemoveAccessRule($rule)
    }
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
    try {
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    $DeniedUsername, 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Deny')))
    }
    catch {
        $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Install' -Context (
            "Could not add Deny ACE; user='{0}'; directory='{1}'" -f $DeniedUsername, $Directory)
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
    $monitorScript = Join-Path $repoRoot 'src\LoginTimeLogger.ps1'
    $templateConfigPath = Join-Path $repoRoot 'config\config.json'
    $csPath = Join-Path $repoRoot 'src\SessionQuery.cs'
    $commonErrorSrc = Join-Path $repoRoot 'src\Common-Error.ps1'
    $updateCheckSrc = Join-Path $repoRoot 'src\Update-Check.ps1'

    $raw = Test-InstallPrerequisites `
        -RepoRoot $repoRoot `
        -MonitorScript $monitorScript `
        -TemplateConfigPath $templateConfigPath `
        -CsPath $csPath

    $targetUsername = [string]$raw.TargetUsername

    $administratorProfile = [string]$raw.AdministratorProfile
    if ([string]::IsNullOrWhiteSpace($administratorProfile)) {
        $administratorProfile = Join-Path $env:SystemDrive 'Users\Administrator'
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

    $null = Initialize-ErrorLog -AdministratorProfile $administratorProfile
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

    if (-not (Test-Path -LiteralPath $administratorProfile)) {
        $null = Write-ErrorMessage -Level WARN -Source 'Install' -Message @"
Administrator profile not found at '$administratorProfile'.
Folders will still be created. If this path is wrong, set AdministratorProfile in config\config.json and re-run Install.ps1.
SystemDrive: $env:SystemDrive
"@
    }

    $adminAppDirectory = Join-Path $administratorProfile 'LoginTimeLogger'
    $runtimeConfigPath = Join-Path $adminAppDirectory 'config.json'

    $logDirectory = [string]$raw.LogDirectory
    if ([string]::IsNullOrWhiteSpace($logDirectory)) {
        $logDirectory = Join-Path $administratorProfile 'LoginTimeLogs'
    }

    $config = [ordered]@{
        TargetUsername       = $targetUsername
        AdministratorProfile = $administratorProfile
        LogDirectory         = $logDirectory
        PollIntervalSeconds  = $pollSeconds
        UpdateEnabled        = $updateEnabled
        UpdateRepoUrl        = $updateRepoUrl
        UpdateBranch         = $updateBranch
        UpdateClonePath      = $updateClonePath
    }
    $configJson = $config | ConvertTo-Json -Depth 4

    # Write runtime config only; leave the project template config.json untouched.
    try {
        Set-ProtectedDirectory -Directory $adminAppDirectory -DeniedUsername $targetUsername
        $configJson | Set-Content -LiteralPath $runtimeConfigPath -Encoding UTF8
        Set-ProtectedDirectory -Directory $logDirectory -DeniedUsername $targetUsername
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Creating protected Administrator folders/config failed; adminApp='{0}'; runtimeConfig='{1}'; logDir='{2}'" -f `
                $adminAppDirectory, $runtimeConfigPath, $logDirectory)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    $installSrc = Join-Path $installRoot 'src'

    try {
        New-Item -ItemType Directory -Path $installSrc -Force | Out-Null
        Copy-Item -LiteralPath $monitorScript -Destination (Join-Path $installSrc 'LoginTimeLogger.ps1') -Force
        Copy-Item -LiteralPath $csPath -Destination (Join-Path $installSrc 'SessionQuery.cs') -Force
        Copy-Item -LiteralPath $commonErrorSrc -Destination (Join-Path $installSrc 'Common-Error.ps1') -Force
        Copy-Item -LiteralPath $updateCheckSrc -Destination (Join-Path $installSrc 'Update-Check.ps1') -Force
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
        $installedAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'BUILTIN\Administrators', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $installedAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'NT AUTHORITY\SYSTEM', 'FullControl', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
        $installedAcl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
                    'BUILTIN\Users', 'ReadAndExecute', 'ContainerInherit,ObjectInherit', 'None', 'Allow')))
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
            -MultipleInstances IgnoreNew

        $principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -LogonType ServiceAccount -RunLevel Highest

        Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force | Out-Null
    }
    catch {
        $details = Format-ErrorDetails -ErrorRecord $_ -Context (
            "Register-ScheduledTask failed; task='{0}'; execute='{1}'; args='{2}'" -f `
                $TaskName, $windowsPowerShell, $argument)
        throw (New-Object System.Exception($details, $_.Exception))
    }

    Write-Host "Installed scheduled task '$TaskName' (At startup, SYSTEM, Highest)."
    Write-Host "Monitor scripts: $installRoot"
    Write-Host "Runtime config:  $runtimeConfigPath"
    Write-Host "Log directory:   $logDirectory"
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
    }
    else {
        Write-Host "Run: Start-ScheduledTask -TaskName '$TaskName'   (or reboot)"
    }
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Install.ps1 failed' -Source 'Install'
    throw
}
