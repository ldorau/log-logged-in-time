#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  One-file bootstrap: install Git if needed, clone the repo, run scripts\Install.ps1.
.DESCRIPTION
  Download and run this script alone from an elevated PowerShell prompt.
  Requires two account names:
    1) administrative account (install/config owner)
    2) measured user (unlocked login time)
.PARAMETER AdminUsername
  Administrative Windows account that owns install/config/logs.
.PARAMETER TargetUsername
  Windows account whose unlocked login time will be measured.
  For testing, this may be the same as AdminUsername.
.EXAMPLE
  .\Bootstrap-Install.ps1 -AdminUsername AdminName -TargetUsername UserName -StartNow
.EXAMPLE
  .\Bootstrap-Install.ps1 AdminName UserName -StartNow
.EXAMPLE
  # Testing with one account for both roles:
  .\Bootstrap-Install.ps1 -AdminUsername AdminName -TargetUsername AdminName -StartNow
.PARAMETER RepoUrl
  Git clone URL (must be the allowlisted project repo by default).
.PARAMETER Branch
  Branch to clone (default main).
.PARAMETER ClonePath
  Where to clone the repository. Default: <USERPROFILE>\log-logged-in-time
.PARAMETER StartNow
  Pass -StartNow to scripts\Install.ps1 (start the scheduled task after install).
.PARAMETER Force
  Remove an existing ClonePath and re-clone.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, Position = 0)]
    [Alias('AdministratorUsername')]
    [string]$AdminUsername,

    [Parameter(Mandatory, Position = 1)]
    [string]$TargetUsername,

    [string]$RepoUrl = 'https://github.com/ldorau/log-logged-in-time.git',

    [string]$Branch = 'main',

    [string]$ClonePath = '',

    [switch]$StartNow,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Update-ProcessPathFromMachine {
    try {
        $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
        $user = [Environment]::GetEnvironmentVariable('Path', 'User')
        if ($machine -or $user) {
            $env:Path = (@($machine, $user) | Where-Object { $_ }) -join ';'
        }
    }
    catch { }
}

function Find-GitExecutable {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }

    foreach ($c in @(
            (Join-Path $env:ProgramFiles 'Git\cmd\git.exe')
            (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe')
            (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe')
        )) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Test-GitInstallerAuthenticode {
    param([Parameter(Mandatory)][string]$InstallerPath)

    $signature = Get-AuthenticodeSignature -LiteralPath $InstallerPath
    if ($signature.Status -ne 'Valid') {
        throw ("Git installer Authenticode signature is not Valid (Status={0})." -f $signature.Status)
    }

    $subject = ''
    if ($signature.SignerCertificate) {
        $subject = [string]$signature.SignerCertificate.Subject
    }
    $allowed = @('Johannes Schindelin', 'Git for Windows', 'GitHub, Inc', 'Microsoft Corporation')
    foreach ($pattern in $allowed) {
        if ($subject -like ("*{0}*" -f $pattern)) {
            Write-Host ("  Authenticode OK: {0}" -f $subject)
            return
        }
    }
    throw ("Git installer publisher is not allowed. Subject={0}" -f $subject)
}

function Install-GitForWindows {
    Write-Host 'Git not found. Downloading and installing Git for Windows...'

    try {
        [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    }
    catch { }

    $archTag = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
    $apiUrl = 'https://api.github.com/repos/git-for-windows/git/releases/latest'
    $headers = @{
        'Accept'     = 'application/vnd.github+json'
        'User-Agent' = 'LoginTimeLogger-Bootstrap'
    }

    $release = Invoke-RestMethod -Uri $apiUrl -Headers $headers -UseBasicParsing
    $asset = @(
        $release.assets |
            Where-Object { $_.name -match ("^Git-.+-{0}\.exe$" -f [regex]::Escape($archTag)) } |
            Select-Object -First 1
    )[0]
    if (-not $asset) {
        throw ("No Git for Windows {0} installer found in the latest release." -f $archTag)
    }

    $installerPath = Join-Path $env:TEMP ([string]$asset.name)
    Write-Host ("  Downloading {0}..." -f $asset.name)
    Invoke-WebRequest -Uri ([string]$asset.browser_download_url) -OutFile $installerPath -UseBasicParsing
    Test-GitInstallerAuthenticode -InstallerPath $installerPath

    $installArgs = @(
        '/VERYSILENT', '/NORESTART', '/NOCANCEL', '/SP-',
        '/CLOSEAPPLICATIONS', '/RESTARTAPPLICATIONS',
        '/COMPONENTS=icons,ext\reg\shellhere,assoc,assoc_sh',
        '/o:PathOption=Cmd'
    )
    Write-Host '  Running silent Git for Windows installer...'
    $proc = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
    Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    if ($proc.ExitCode -ne 0) {
        throw ("Git for Windows installer exited with code {0}." -f $proc.ExitCode)
    }

    Update-ProcessPathFromMachine
    $gitPath = Find-GitExecutable
    if (-not $gitPath) {
        throw 'Git installer finished, but git.exe was not found afterward.'
    }
    return $gitPath
}

function Test-TrustedRepoUrl {
    param([Parameter(Mandatory)][string]$Url)

    try {
        $uri = [Uri]$Url
    }
    catch {
        return $false
    }
    if (-not $uri.IsAbsoluteUri -or $uri.Scheme -ne 'https') { return $false }
    if (-not [string]::Equals($uri.Host, 'github.com', [StringComparison]::OrdinalIgnoreCase)) { return $false }
    $path = $uri.AbsolutePath.TrimEnd('/').ToLowerInvariant()
    return (@('/ldorau/log-logged-in-time', '/ldorau/log-logged-in-time.git') -contains $path)
}

function Invoke-Git {
    <#
    .SYNOPSIS
      Runs git without treating stderr progress ("From https://...") as a terminating error
      under $ErrorActionPreference = 'Stop'.
    #>
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $previousEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $GitExe @Arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousEap
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = $output
    }
}

# --- main ---
try {
    Write-Host 'LoginTimeLogger one-file bootstrap' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-IsAdministrator)) {
        throw 'Re-run this script from an elevated PowerShell (Run as administrator).'
    }

    if (-not (Test-TrustedRepoUrl -Url $RepoUrl)) {
        throw ("RepoUrl is not allowed. Use https://github.com/ldorau/log-logged-in-time.git (got: {0})" -f $RepoUrl)
    }

    if ([string]::IsNullOrWhiteSpace($ClonePath)) {
        $homeRoot = $env:USERPROFILE
        if ([string]::IsNullOrWhiteSpace($homeRoot) -or ($homeRoot -match '\\System32\\config\\systemprofile$')) {
            $homeRoot = Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME)
        }
        $ClonePath = Join-Path $homeRoot 'log-logged-in-time'
    }

    Write-Host ("AdminUsername  : {0}" -f $AdminUsername)
    Write-Host ("TargetUsername : {0}" -f $TargetUsername)
    Write-Host ("ClonePath      : {0}" -f $ClonePath)
    Write-Host ("RepoUrl        : {0}" -f $RepoUrl)
    Write-Host ("Branch         : {0}" -f $Branch)
    Write-Host ''

    $gitExe = Find-GitExecutable
    if (-not $gitExe) {
        $gitExe = Install-GitForWindows
        Write-Host ("Git installed: {0}" -f $gitExe) -ForegroundColor Green
    }
    else {
        Write-Host ("Git found: {0}" -f $gitExe)
    }

    if ((Test-Path -LiteralPath $ClonePath) -and $Force) {
        Write-Host ("Removing existing clone (-Force): {0}" -f $ClonePath)
        Remove-Item -LiteralPath $ClonePath -Recurse -Force
    }

    if (-not (Test-Path -LiteralPath (Join-Path $ClonePath '.git'))) {
        $parent = Split-Path -Parent $ClonePath
        if (-not (Test-Path -LiteralPath $parent)) {
            New-Item -ItemType Directory -Path $parent -Force | Out-Null
        }
        Write-Host ("Cloning {0} (branch {1})..." -f $RepoUrl, $Branch)
        $clone = Invoke-Git -GitExe $gitExe -Arguments @('clone', '--branch', $Branch, '--single-branch', $RepoUrl, $ClonePath)
        if ($clone.ExitCode -ne 0) {
            throw ("git clone failed (exit {0}): {1}" -f $clone.ExitCode, ($clone.Output | Out-String))
        }
    }
    else {
        Write-Host ("Repository already present at {0}; fetching latest {1}..." -f $ClonePath, $Branch)
        $fetch = Invoke-Git -GitExe $gitExe -Arguments @('-C', $ClonePath, 'fetch', 'origin', $Branch)
        if ($fetch.ExitCode -ne 0) {
            throw ("git fetch failed (exit {0}): {1}" -f $fetch.ExitCode, ($fetch.Output | Out-String))
        }
        $null = Invoke-Git -GitExe $gitExe -Arguments @('-C', $ClonePath, 'checkout', $Branch)
        $pull = Invoke-Git -GitExe $gitExe -Arguments @('-C', $ClonePath, 'pull', '--ff-only', 'origin', $Branch)
        if ($pull.ExitCode -ne 0) {
            Write-Host ("Warning: git pull --ff-only failed; continuing with local tree. Detail: {0}" -f ($pull.Output | Out-String)) -ForegroundColor Yellow
        }
    }

    $installScript = Join-Path $ClonePath 'scripts\Install.ps1'
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Install.ps1 missing after clone: $installScript"
    }

    Write-Host 'Running scripts\Install.ps1...'
    Push-Location -LiteralPath $ClonePath
    try {
        $installArgs = @{
            AdminUsername  = $AdminUsername
            TargetUsername = $TargetUsername
        }
        if ($StartNow) {
            $installArgs['StartNow'] = $true
        }
        & $installScript @installArgs
    }
    finally {
        Pop-Location
    }

    Write-Host ''
    Write-Host 'Bootstrap finished.' -ForegroundColor Green
    Write-Host ("Repo clone: {0}" -f $ClonePath)
}
catch {
    Write-Host ''
    Write-Host '---------- BOOTSTRAP ERROR ----------' -ForegroundColor Red
    Write-Host $_.Exception.ToString() -ForegroundColor Red
    if ($_.ScriptStackTrace) {
        Write-Host $_.ScriptStackTrace -ForegroundColor Red
    }
    Write-Host '-------------------------------------' -ForegroundColor Red
    exit 1
}
