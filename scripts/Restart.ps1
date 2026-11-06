#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Restarts only the LoginTimeLogger monitor scheduled task.
.DESCRIPTION
  Compares repo template config files to the installed runtime configs and
  merges any missing fields (existing values unchanged), then stops and
  starts the LoginTimeLogger task. Does not reinstall Program Files, pull
  git, or touch the lock-signal task.
.PARAMETER TaskName
  Scheduled task name (default LoginTimeLogger).
.PARAMETER ConfigPath
  Runtime config JSON. Default: path from the LoginTimeLogger task -ConfigPath
  argument, then %USERPROFILE%\LoginTimeLogger\config.json.
.PARAMETER TemplateRoot
  Directory that contains config\config.json and config\smtp.json (defaults to
  UpdateClonePath from the runtime config when present, otherwise this repo).
.PARAMETER SkipConfigMerge
  Skip template compare/merge; only restart the task.
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
    [switch]$SkipConfigMerge
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

function Resolve-TemplateRoot {
    param(
        [string]$TemplateRoot,
        [Parameter(Mandatory)][string]$RepoRoot,
        $RuntimeConfig
    )

    if (-not [string]::IsNullOrWhiteSpace($TemplateRoot)) {
        if (-not (Test-Path -LiteralPath (Join-Path $TemplateRoot 'config\config.json'))) {
            throw "TemplateRoot missing config\config.json: '$TemplateRoot'."
        }
        return $TemplateRoot
    }

    $clonePath = [string](Get-OptionalPropertyValue -InputObject $RuntimeConfig -Name 'UpdateClonePath')
    if (-not [string]::IsNullOrWhiteSpace($clonePath) -and
        (Test-Path -LiteralPath (Join-Path $clonePath 'config\config.json'))) {
        return $clonePath
    }

    if (Test-Path -LiteralPath (Join-Path $RepoRoot 'config\config.json')) {
        return $RepoRoot
    }

    throw @"
Could not locate template config files (config\config.json).
Pass -TemplateRoot to a checkout that contains them, or set UpdateClonePath in the runtime config.
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
    Write-Host ("Runtime config: {0}" -f $resolvedConfigPath)

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
        AdminUsername          = $adminUsername
        AdministratorProfile   = $adminProfile
        ConfigPath             = $resolvedConfigPath
        UpdateClonePath        = [string](Get-OptionalPropertyValue -InputObject $runtimeRaw -Name 'UpdateClonePath')
    }

    if (-not $SkipConfigMerge) {
        $templateRootResolved = Resolve-TemplateRoot `
            -TemplateRoot $TemplateRoot `
            -RepoRoot $repoRoot `
            -RuntimeConfig $runtimeRaw
        Write-Host ("Template root:  {0}" -f $templateRootResolved)

        $templateConfig = Join-Path $templateRootResolved 'config\config.json'
        $templateSmtp = Join-Path $templateRootResolved 'config\smtp.json'
        $destConfig = $resolvedConfigPath
        $destSmtp = Join-Path $adminAppDirectory 'smtp.json'

        $configDiff = Get-MissingTemplateKeys -TemplatePath $templateConfig -DestPath $destConfig
        $smtpDiff = Get-MissingTemplateKeys -TemplatePath $templateSmtp -DestPath $destSmtp

        $needsMerge = $false
        if ($configDiff.TemplateMissing) {
            Write-Host ("WARNING: template missing: {0}" -f $templateConfig) -ForegroundColor Yellow
        }
        elseif ($configDiff.DestMissing -or $configDiff.AddedKeys.Count -gt 0) {
            $needsMerge = $true
            Write-Host ("config.json differs from template (missing: {0})" -f `
                    ($(if ($configDiff.AddedKeys.Count -gt 0) { $configDiff.AddedKeys -join ', ' } else { 'n/a' })))
        }
        else {
            Write-Host 'config.json: no new template fields.'
        }

        if ($smtpDiff.TemplateMissing) {
            Write-Host ("WARNING: template missing: {0}" -f $templateSmtp) -ForegroundColor Yellow
        }
        elseif ($smtpDiff.DestMissing -or $smtpDiff.AddedKeys.Count -gt 0) {
            $needsMerge = $true
            Write-Host ("smtp.json differs from template (missing: {0})" -f `
                    ($(if ($smtpDiff.AddedKeys.Count -gt 0) { $smtpDiff.AddedKeys -join ', ' } else { 'n/a' })))
        }
        else {
            Write-Host 'smtp.json: no new template fields.'
        }

        if ($needsMerge) {
            Write-Host 'Merging missing template fields into installed configs...' -ForegroundColor Cyan
            Merge-InstalledConfigFilesFromRepo `
                -ClonePath $templateRootResolved `
                -AdminAppDirectory $adminAppDirectory `
                -ConfigPath $destConfig `
                -Config $configForMerge
        }
        else {
            Write-Host 'Installed configs already include all template fields; no merge needed.'
        }
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
