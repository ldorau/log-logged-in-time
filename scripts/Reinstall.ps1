#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Pulls the latest repo (when this folder is a git clone) and re-runs Install
  with -StartNow so Program Files and the LoginTimeLogger task are refreshed.
.DESCRIPTION
  1) Reads AdminUsername and TargetUsername from the current runtime config
     (LoginTimeLogger scheduled task -ConfigPath, or -ConfigPath).
  2) Optionally updates this working copy from origin (ff-only pull; falls
     back to reset --hard origin/<branch> if needed).
  3) Runs scripts\Install.ps1 -StartNow to copy files, re-register tasks, and
     start LoginTimeLogger (+ lock-signal when possible).
  4) Runs scripts\Status.ps1 to show task/monitor status.
.PARAMETER ConfigPath
  Runtime config JSON. Default: path from the LoginTimeLogger task -ConfigPath
  argument.
.PARAMETER TaskName
  Scheduled task name used to locate the runtime config (default LoginTimeLogger).
.PARAMETER SkipGitPull
  Do not run git fetch/pull; only reinstall from the current working tree.
.PARAMETER Branch
  Remote branch to update to (default: main).
.EXAMPLE
  .\scripts\Reinstall.ps1
.EXAMPLE
  .\scripts\Reinstall.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
.EXAMPLE
  .\scripts\Reinstall.ps1 -SkipGitPull
#>
[CmdletBinding()]
param(
    [string]$ConfigPath,
    [string]$TaskName = 'LoginTimeLogger',
    [switch]$SkipGitPull,
    [string]$Branch = 'main'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$installScript = Join-Path $scriptDir 'Install.ps1'
$statusScript = Join-Path $scriptDir 'Status.ps1'
if (-not (Test-Path -LiteralPath $installScript)) {
    throw "Install.ps1 not found at '$installScript'."
}
if (-not (Test-Path -LiteralPath $statusScript)) {
    throw "Status.ps1 not found at '$statusScript'."
}

$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}
. $commonErrorPath

function Find-GitExecutable {
    $cmd = Get-Command git.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    $candidates = @(
        (Join-Path ${env:ProgramFiles} 'Git\cmd\git.exe')
        (Join-Path ${env:ProgramFiles(x86)} 'Git\cmd\git.exe')
        (Join-Path $env:LocalAppData 'Programs\Git\cmd\git.exe')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) { return $c }
    }
    return $null
}

function Invoke-GitInRepo {
    <#
      Runs git with stderr merged to output. Git writes progress to stderr;
      with $ErrorActionPreference Stop that becomes a terminating NativeCommandError
      even when exit code is 0. Use Continue for the call and trust LASTEXITCODE.
    #>
    param(
        [Parameter(Mandatory)][string]$GitExe,
        [Parameter(Mandatory)][string]$RepoRoot,
        [Parameter(Mandatory)][string[]]$Arguments
    )

    $prevEap = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $GitExe -C $RepoRoot @Arguments 2>&1
        $exitCode = [int]$LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $prevEap
    }

    return [pscustomobject]@{
        ExitCode = $exitCode
        Output   = (($output | ForEach-Object { "$_" }) -join [Environment]::NewLine)
    }
}

function Resolve-RuntimeConfigPath {
    param(
        [string]$ConfigPath,
        [string]$TaskName
    )

    if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        if (-not (Test-Path -LiteralPath $ConfigPath)) {
            throw "ConfigPath not found: '$ConfigPath'."
        }
        return $ConfigPath
    }

    $fromTask = Get-LoginTimeLoggerRuntimeConfigPath -TaskName $TaskName
    if ($fromTask) {
        return $fromTask
    }

    $guess = Join-Path $env:USERPROFILE 'LoginTimeLogger\config.json'
    if (Test-Path -LiteralPath $guess) {
        return $guess
    }

    throw @"
Could not find the current runtime config.
Pass -ConfigPath to the installed file, for example:
  .\scripts\Reinstall.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
Or ensure scheduled task '$TaskName' exists with a -ConfigPath argument.
"@
}

function Get-AccountsFromConfig {
    param([Parameter(Mandatory)][string]$Path)

    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    $admin = [string]$raw.AdminUsername
    $target = [string]$raw.TargetUsername
    $profile = [string]$raw.AdministratorProfile

    if ([string]::IsNullOrWhiteSpace($admin) -and -not [string]::IsNullOrWhiteSpace($profile)) {
        $admin = Split-Path -Leaf $profile
    }

    if ([string]::IsNullOrWhiteSpace($admin) -or [string]::IsNullOrWhiteSpace($target)) {
        throw @"
Runtime config is missing AdminUsername and/or TargetUsername.
Config: $Path
AdminUsername: '$(if ($admin) { $admin } else { '(empty)' })'
TargetUsername: '$(if ($target) { $target } else { '(empty)' })'
"@
    }

    return [pscustomobject]@{
        ConfigPath             = $Path
        AdminUsername          = $admin
        TargetUsername         = $target
        AdministratorProfile   = $profile
    }
}

try {
    $null = Initialize-ErrorLog -ConfigPath (Join-Path $repoRoot 'config\config.json')
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))
    Write-Host '=== LoginTimeLogger reinstall ===' -ForegroundColor Cyan
    Write-Host ("Repo root: {0}" -f $repoRoot)

    $resolvedConfigPath = Resolve-RuntimeConfigPath -ConfigPath $ConfigPath -TaskName $TaskName
    $accounts = Get-AccountsFromConfig -Path $resolvedConfigPath
    Write-Host ("Config:         {0}" -f $accounts.ConfigPath)
    Write-Host ("AdminUsername:  {0}" -f $accounts.AdminUsername)
    Write-Host ("TargetUsername: {0}" -f $accounts.TargetUsername)

    if (-not [string]::IsNullOrWhiteSpace($accounts.AdministratorProfile)) {
        $null = Initialize-ErrorLog -AdministratorProfile $accounts.AdministratorProfile
        Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))
    }
    Write-Host ''

    if (-not $SkipGitPull) {
        $gitDir = Join-Path $repoRoot '.git'
        if (-not (Test-Path -LiteralPath $gitDir)) {
            Write-Host 'No .git directory here; skipping repo pull (will reinstall from current files).' -ForegroundColor Yellow
        }
        else {
            $gitExe = Find-GitExecutable
            if (-not $gitExe) {
                Write-Warning 'git.exe not found; skipping repo pull (will reinstall from current files).'
            }
            else {
                Write-Host ("Updating git clone from origin/{0}..." -f $Branch) -ForegroundColor Cyan
                $fetch = Invoke-GitInRepo -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('fetch', 'origin', $Branch)
                if ($fetch.ExitCode -ne 0) {
                    throw ("git fetch failed (exit {0}): {1}" -f $fetch.ExitCode, $fetch.Output)
                }

                $pull = Invoke-GitInRepo -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('pull', '--ff-only', 'origin', $Branch)
                if ($pull.ExitCode -ne 0) {
                    Write-Warning ("git pull --ff-only failed; hard-resetting to origin/{0}. Detail: {1}" -f $Branch, $pull.Output)
                    $reset = Invoke-GitInRepo -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('reset', '--hard', ("origin/{0}" -f $Branch))
                    if ($reset.ExitCode -ne 0) {
                        throw ("git reset --hard failed (exit {0}): {1}" -f $reset.ExitCode, $reset.Output)
                    }
                }

                $headResult = Invoke-GitInRepo -GitExe $gitExe -RepoRoot $repoRoot -Arguments @('rev-parse', '--short', 'HEAD')
                $head = ($headResult.Output).Trim()
                Write-Host ("Repo updated to {0}." -f $head) -ForegroundColor Green
            }
        }
    }
    else {
        Write-Host 'Skipping git pull (-SkipGitPull).' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Running Install.ps1 -StartNow ...' -ForegroundColor Cyan
    & $installScript `
        -AdminUsername $accounts.AdminUsername `
        -TargetUsername $accounts.TargetUsername `
        -TaskName $TaskName `
        -StartNow
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw ("Install.ps1 exited with code {0}." -f $LASTEXITCODE)
    }

    Write-Host ''
    Write-Host 'Running Status.ps1 ...' -ForegroundColor Cyan
    $statusArgs = @{ TaskName = $TaskName }
    if (-not [string]::IsNullOrWhiteSpace($accounts.ConfigPath)) {
        $statusArgs['ConfigPath'] = $accounts.ConfigPath
    }
    & $statusScript @statusArgs
    if ($LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        Write-Warning ("Status.ps1 exited with code {0}." -f $LASTEXITCODE)
    }

    Write-Host ''
    Write-Host 'Reinstall finished.' -ForegroundColor Green
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Reinstall.ps1 failed' -Source 'Reinstall'
    throw
}
