#Requires -Version 5.1
<#
.SYNOPSIS
  Background WTS probe worker for Test-WtsLockProbe.ps1.
.DESCRIPTION
  Polls SessionQuery.IsUserUnlocked on an interval and appends samples to a
  TEMP log file. Intended to keep running while the interactive desktop is
  locked (Win+L). Does not read or write Administrator LoginTimeLogs.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$TargetUsername,
    [Parameter(Mandatory)][string]$ProbeFile,
    [Parameter(Mandatory)][string]$SessionQueryCsPath,
    [int]$IntervalSeconds = 3,
    [int]$TimeoutSeconds = 300
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($IntervalSeconds -lt 1) { $IntervalSeconds = 1 }
if ($TimeoutSeconds -lt 5) { $TimeoutSeconds = 5 }

$dir = Split-Path -Parent $ProbeFile
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

if (-not (Test-Path -LiteralPath $SessionQueryCsPath)) {
    throw "SessionQuery.cs not found: $SessionQueryCsPath"
}

if (-not ('SessionQuery' -as [type])) {
    Add-Type -TypeDefinition (Get-Content -LiteralPath $SessionQueryCsPath -Raw -Encoding UTF8) `
        -Language CSharp -ErrorAction Stop
}

function Write-ProbeLine {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    Add-Content -LiteralPath $ProbeFile -Value $line -Encoding UTF8
}

Write-ProbeLine -Message (
    "[PROBE] started target='{0}' interval={1}s timeout={2}s" -f `
        $TargetUsername, $IntervalSeconds, $TimeoutSeconds)

$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
try {
    while ((Get-Date) -lt $deadline) {
        $unlocked = $false
        $err = ''
        try {
            $unlocked = [SessionQuery]::IsUserUnlocked($TargetUsername)
            $source = [SessionQuery]::LastLockSource
            $flags = [SessionQuery]::LastWtsSessionFlags
            $cal = [SessionQuery]::WtsPolarityCalibrated
            $oneMeansLocked = [SessionQuery]::WtsOneMeansLocked
            Write-ProbeLine -Message (
                ("unlocked={0} source={1} flags={2} calibrated={3} oneMeansLocked={4}" -f `
                    $unlocked, $source, $flags, $cal, $oneMeansLocked))
        }
        catch {
            $err = $_.Exception.Message
            Write-ProbeLine -Message ("ERROR {0}" -f $err)
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}
finally {
    Write-ProbeLine -Message '[PROBE] stopped'
}
