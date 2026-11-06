#Requires -Version 5.1
#Requires -RunAsAdministrator
<#
.SYNOPSIS
  Restarts only the LoginTimeLogger monitor scheduled task.
.DESCRIPTION
  Stops the LoginTimeLogger task if it is running, then starts it again.
  Does not reinstall files, pull git, or touch the lock-signal task.
.PARAMETER TaskName
  Scheduled task name (default LoginTimeLogger).
.EXAMPLE
  .\scripts\Restart.ps1
.EXAMPLE
  .\scripts\Restart.ps1 -TaskName LoginTimeLogger
#>
[CmdletBinding()]
param(
    [string]$TaskName = 'LoginTimeLogger'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw "Common-Error.ps1 missing at '$commonErrorPath'."
}
. $commonErrorPath

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
    $null = Initialize-ErrorLog
    Write-Host ("Error log file: {0}" -f (Get-ErrorLogPath))

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
