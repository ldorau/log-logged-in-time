#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Publishes monitor files (optional) and restarts the LoginTimeLogger task.
.DESCRIPTION
  By default copies src/scripts from this Restart.ps1 checkout into
  Program Files\LoginTimeLogger, merges missing config fields from the
  same checkout (not a stale UpdateClonePath), then restarts the
  LoginTimeLogger task. Use after git pull when self-update is stuck.
  Does not git pull and does not touch the lock-signal task.
.PARAMETER TaskName
  Scheduled task name (default LoginTimeLogger).
.PARAMETER ConfigPath
  Runtime config JSON. Default: path from the LoginTimeLogger task -ConfigPath
  argument, then %USERPROFILE%\LoginTimeLogger\config.json.
.PARAMETER TemplateRoot
  Directory that contains config\config.json and src\. Default: this
  Restart.ps1 checkout (same tree used for publish). Falls back to
  UpdateClonePath only when this checkout has no src\LoginTimeLogger.ps1.
.PARAMETER SkipConfigMerge
  Skip template compare/merge.
.PARAMETER SkipPublish
  Skip copying files into Program Files; only merge/restart.
.EXAMPLE
  .\scripts\Restart.ps1
.EXAMPLE
  .\scripts\Restart.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'LoginTimeLogger',
    [string]$ConfigPath = '',
    [string]$TemplateRoot = '',
    [switch]$SkipConfigMerge,
    [switch]$SkipPublish
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
$updateCheckPath = Join-Path $repoRoot 'src\Update-Check.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}
if (-not (Test-Path -LiteralPath $updateCheckPath)) {
    throw "Update-Check.ps1 missing at '$updateCheckPath'."
}
. $commonErrorPath

# Used by Update-Check merge helpers when dotted into this script.
function Write-LoggerEvent {
    param(
        [Parameter(Mandatory, Position = 0)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')]
        [string]$Level = 'INFO'
    )
    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        default { 'Gray' }
    }
    Write-Host ("[{0}] {1}" -f $Level, $Message) -ForegroundColor $color
}

. $updateCheckPath

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
  .\scripts\Restart.ps1 -ConfigPath 'C:\Users\AdminName\LoginTimeLogger\config.json'
Or ensure scheduled task '$TaskName' exists with a -ConfigPath argument.
"@
}

function Get-MissingTemplateKeys {
    param(
        [Parameter(Mandatory)][string]$TemplatePath,
        [Parameter(Mandatory)][string]$DestPath
    )

    if (-not (Test-Path -LiteralPath $TemplatePath)) {
        return [pscustomobject]@{
            TemplateMissing = $true
            DestMissing     = $false
            AddedKeys       = @()
        }
    }
    if (-not (Test-Path -LiteralPath $DestPath)) {
        return [pscustomobject]@{
            TemplateMissing = $false
            DestMissing     = $true
            AddedKeys       = @('(entire file)')
        }
    }

    $templateObj = Get-Content -LiteralPath $TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
    $existingObj = Get-Content -LiteralPath $DestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $addedKeys = [System.Collections.Generic.List[string]]::new()
    $null = Merge-JsonConfigPreserveExisting `
        -Existing $existingObj `
        -Template $templateObj `
        -AddedKeys $addedKeys

    return [pscustomobject]@{
        TemplateMissing = $false
        DestMissing     = $false
        AddedKeys       = @($addedKeys.ToArray())
    }
}

function Resolve-RestartSourceRoot {
    <#
      Same tree for Program Files publish and config merge.
      Prefer the checkout that contains this Restart.ps1 so a stale
      UpdateClonePath cannot publish new code while merging an old
      config template (which then reports "no merge needed").
    #>
    param(
        [string]$TemplateRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        $RuntimeConfig
    )

    if (-not [string]::IsNullOrWhiteSpace($TemplateRoot)) {
        if (-not (Test-Path -LiteralPath (Join-Path $TemplateRoot 'config\config.json'))) {
            throw "TemplateRoot missing config\config.json: '$TemplateRoot'."
        }
        if (-not (Test-Path -LiteralPath (Join-Path $TemplateRoot 'src\LoginTimeLogger.ps1'))) {
            throw "TemplateRoot missing src\LoginTimeLogger.ps1: '$TemplateRoot'."
        }
        return $TemplateRoot
    }

    if ((Test-Path -LiteralPath (Join-Path $RepoRoot 'config\config.json')) -and
        (Test-Path -LiteralPath (Join-Path $RepoRoot 'src\LoginTimeLogger.ps1'))) {
        return $RepoRoot
    }

    $clonePath = [string](Get-OptionalPropertyValue -InputObject $RuntimeConfig -Name 'UpdateClonePath')
    if (-not [string]::IsNullOrWhiteSpace($clonePath) -and
        (Test-Path -LiteralPath (Join-Path $clonePath 'config\config.json')) -and
        (Test-Path -LiteralPath (Join-Path $clonePath 'src\LoginTimeLogger.ps1'))) {
        return $clonePath
    }

    throw @"
Could not locate a publish/merge source (config\config.json + src\LoginTimeLogger.ps1).
Pass -TemplateRoot to a checkout that contains them, or repair UpdateClonePath.
"@
}

function Start-LoginTimeLoggerTask {
    param([Parameter(Mandatory)][string]$Name)

    try {
        Start-ScheduledTask -TaskName $Name -ErrorAction Stop
        return
    }
    catch {
        $schtasks = Join-Path $env:SystemRoot 'System32\schtasks.exe'
        $proc = Start-Process -FilePath $schtasks -ArgumentList @('/Run', '/TN', $Name) `
            -Wait -PassThru -WindowStyle Hidden
        if ($null -eq $proc -or $proc.ExitCode -ne 0) {
            $exit = if ($null -ne $proc) { $proc.ExitCode } else { '(null)' }
            throw ("Start-ScheduledTask and schtasks /Run both failed for '{0}' (schtasks exit={1})." -f $Name, $exit)
        }
    }
}

try {
    $resolvedConfigPath = Resolve-RuntimeConfigPath -ConfigPath $ConfigPath -TaskName $TaskName
    $null = Initialize-ErrorLog -ConfigPath $resolvedConfigPath
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))
    Write-Host '=== LoginTimeLogger restart ===' -ForegroundColor Cyan

    $runtimeRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $adminProfile = [string](Get-OptionalPropertyValue -InputObject $runtimeRaw -Name 'AdministratorProfile')
    if ([string]::IsNullOrWhiteSpace($adminProfile)) {
        $adminProfile = Split-Path -Parent (Split-Path -Parent $resolvedConfigPath)
    }
    $adminAppDirectory = Join-Path $adminProfile 'LoginTimeLogger'
    $adminUsername = [string](Get-OptionalPropertyValue -InputObject $runtimeRaw -Name 'AdminUsername')
    if ([string]::IsNullOrWhiteSpace($adminUsername) -and -not [string]::IsNullOrWhiteSpace($adminProfile)) {
        $adminUsername = Split-Path -Leaf $adminProfile
    }

    $configForMerge = [pscustomobject]@{
        AdminUsername        = $adminUsername
        AdministratorProfile = $adminProfile
        ConfigPath           = $resolvedConfigPath
        UpdateClonePath      = [string](Get-OptionalPropertyValue `
                -InputObject $runtimeRaw -Name 'UpdateClonePath')
    }

    # One source tree for both publish and config merge (never publish from
    # this checkout while merging a stale UpdateClonePath template).
    $sourceRoot = Resolve-RestartSourceRoot `
        -TemplateRoot $TemplateRoot `
        -RepoRoot $repoRoot `
        -RuntimeConfig $runtimeRaw
    $templateConfigPath = Join-Path $sourceRoot 'config\config.json'
    Write-Host ("Source root:           {0}" -f $sourceRoot)
    Write-Host ("Template config:       {0}" -f $templateConfigPath)
    Write-Host ("Installed/used config: {0}" -f $resolvedConfigPath)

    $installRoot = Join-Path $env:ProgramFiles 'LoginTimeLogger'
    if (-not $SkipPublish) {
        Write-Host ("Publishing Program Files from '{0}' into '{1}'..." -f `
                $sourceRoot, $installRoot) -ForegroundColor Cyan
        Publish-InstalledFilesFromRepo `
            -ClonePath $sourceRoot `
            -InstallRoot $installRoot

        # Record tip when possible so the next self-update is not confused.
        $gitExe = $null
        if (Get-Command Find-GitExecutable -ErrorAction SilentlyContinue) {
            $gitExe = Find-GitExecutable
        }
        if ($gitExe -and (Test-Path -LiteralPath (Join-Path $sourceRoot '.git'))) {
            $head = Invoke-GitCommand -GitExe $gitExe -RepoPath $sourceRoot `
                -Arguments @('rev-parse', 'HEAD')
            if ($head.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($head.Output)) {
                Set-InstalledCommit -InstallRoot $installRoot -CommitSha $head.Output.Trim()
                Write-Host ("installed-commit.txt <- {0}" -f `
                        $head.Output.Trim().ToLowerInvariant())
            }
        }

        # Drop a stuck/corrupt update-state so the new monitor does not
        # inherit a hammering NextUpdateCheckUtc=now death spiral.
        $updateStatePath = Get-UpdateStatePath -AdminAppDirectory $adminAppDirectory
        if (Test-Path -LiteralPath $updateStatePath) {
            Write-Host ("Resetting update-state: {0}" -f $updateStatePath)
        }
        Write-UpdateState -Path $updateStatePath -State (New-UpdateStateObject `
                -NextUpdateCheckUtc ([datetime]::UtcNow.AddMinutes(2).ToString('o')) `
                -LastResult 'restart-published')
    }
    else {
        Write-Host 'Skipping Program Files publish (-SkipPublish).'
    }

    if (-not $SkipConfigMerge) {
        $templateConfig = Join-Path $sourceRoot 'config\config.json'
        $templateSmtp = Join-Path $sourceRoot 'config\smtp.json'
        $destConfig = $resolvedConfigPath
        $destSmtp = Join-Path $adminAppDirectory 'smtp.json'

        $configDiff = Get-MissingTemplateKeys -TemplatePath $templateConfig -DestPath $destConfig
        $smtpDiff = Get-MissingTemplateKeys -TemplatePath $templateSmtp -DestPath $destSmtp

        if ($configDiff.TemplateMissing) {
            throw ("Template missing: {0}" -f $templateConfig)
        }
        if ($configDiff.DestMissing -or $configDiff.AddedKeys.Count -gt 0) {
            Write-Host ("config.json missing template field(s): {0}" -f `
                    ($(if ($configDiff.AddedKeys.Count -gt 0) {
                        $configDiff.AddedKeys -join ', '
                    } else { '(entire file)' })))
        }
        else {
            Write-Host 'config.json: already has all template fields (merge still runs; idempotent).'
        }

        if ($smtpDiff.TemplateMissing) {
            Write-Host ("WARNING: smtp template missing: {0}" -f $templateSmtp) `
                -ForegroundColor Yellow
        }
        elseif ($smtpDiff.DestMissing -or $smtpDiff.AddedKeys.Count -gt 0) {
            Write-Host ("smtp.json missing template field(s): {0}" -f `
                    ($(if ($smtpDiff.AddedKeys.Count -gt 0) {
                        $smtpDiff.AddedKeys -join ', '
                    } else { '(entire file)' })))
        }
        else {
            Write-Host 'smtp.json: already has all template fields (merge still runs; idempotent).'
        }

        # Always merge from the same sourceRoot used for publish. Do not skip
        # when a stale UpdateClonePath template previously looked complete.
        Write-Host ("Merging template fields from '{0}' into installed configs..." -f `
                $sourceRoot) -ForegroundColor Cyan
        Merge-InstalledConfigFilesFromRepo `
            -ClonePath $sourceRoot `
            -AdminAppDirectory $adminAppDirectory `
            -ConfigPath $destConfig `
            -Config $configForMerge `
            -ThrowOnError
    }
    else {
        Write-Host 'Skipping config compare/merge (-SkipConfigMerge).'
    }

    $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if (-not $task) {
        throw @"
Scheduled task '$TaskName' was not found.
Install first: .\scripts\Install.ps1 -AdminUsername <admin> -TargetUsername <user> -StartNow
"@
    }

    $infoBefore = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ("Task '{0}' state before restart: {1}" -f $TaskName, $task.State)

    if ($task.State -eq 'Running') {
        Write-Host ("Stopping '{0}'..." -f $TaskName)
        try {
            Stop-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        }
        catch {
            $null = Write-VerboseError -ErrorRecord $_ -Level Warning -Source 'Restart' -Context (
                "Stop-ScheduledTask failed for '{0}'; will still try Start-ScheduledTask" -f $TaskName)
        }
        # Brief pause so the monitor process / mutex can release before start.
        Start-Sleep -Seconds 2
    }

    Write-Host ("Starting '{0}'..." -f $TaskName)
    Start-LoginTimeLoggerTask -Name $TaskName
    Start-Sleep -Seconds 1

    $taskAfter = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
    $infoAfter = Get-ScheduledTaskInfo -TaskName $TaskName -ErrorAction SilentlyContinue
    Write-Host ("Task '{0}' state after restart: {1}" -f $TaskName, $taskAfter.State)
    if ($null -ne $infoAfter) {
        Write-Host ("LastRun: {0} | LastResult: 0x{1:X8}" -f `
                $infoAfter.LastRunTime,
                (ConvertTo-UInt32Code -Value $infoAfter.LastTaskResult))
    }
    if ($null -ne $infoBefore -and $null -ne $infoAfter) {
        Write-Host ("Previous LastRun was: {0}" -f $infoBefore.LastRunTime)
    }

    if ($taskAfter.State -ne 'Running') {
        Write-Host ("WARNING: task state is '{0}' (expected Running). Check Status.ps1 / errors.log." -f `
                $taskAfter.State) -ForegroundColor Yellow
        exit 1
    }

    Write-Host 'Monitor restart requested successfully.' -ForegroundColor Green
    exit 0
}
catch {
    $null = Write-VerboseError -ErrorRecord $_ -Context 'Restart.ps1 failed' -Source 'Restart'
    throw
}
