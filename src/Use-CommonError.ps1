#Requires -Version 5.1
<#
.SYNOPSIS
  Dot-source Common-Error.ps1 (and SMTP helper) from src/ or Program Files.
.DESCRIPTION
  From scripts/:  . (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\Use-CommonError.ps1')
  From src/:      . (Join-Path $PSScriptRoot 'Use-CommonError.ps1')
  Or pass -StartDirectory. Initializes errors.log and SMTP alerts when possible.
#>
[CmdletBinding()]
param(
    [string]$StartDirectory = ''
)

$here = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($here) -and $MyInvocation.MyCommand.Path) {
    $here = Split-Path -Parent $MyInvocation.MyCommand.Path
}

$roots = New-Object System.Collections.Generic.List[string]
if (-not [string]::IsNullOrWhiteSpace($StartDirectory)) {
    $roots.Add($StartDirectory)
    $roots.Add((Join-Path $StartDirectory 'src'))
    $parent = Split-Path -Parent $StartDirectory
    if (-not [string]::IsNullOrWhiteSpace($parent)) {
        $roots.Add($parent)
        $roots.Add((Join-Path $parent 'src'))
    }
}
if (-not [string]::IsNullOrWhiteSpace($here)) {
    $roots.Add($here)
    $roots.Add((Join-Path $here 'src'))
    $parentHere = Split-Path -Parent $here
    if (-not [string]::IsNullOrWhiteSpace($parentHere)) {
        $roots.Add($parentHere)
        $roots.Add((Join-Path $parentHere 'src'))
    }
}
$roots.Add((Join-Path $env:ProgramFiles 'LoginTimeLogger\src'))

$commonError = $null
foreach ($root in $roots) {
    if ([string]::IsNullOrWhiteSpace($root)) { continue }
    $candidate = Join-Path $root 'Common-Error.ps1'
    if (Test-Path -LiteralPath $candidate) {
        $commonError = $candidate
        break
    }
}
if ([string]::IsNullOrWhiteSpace($commonError)) {
    throw 'Common-Error.ps1 not found (repo src/ or Program Files\LoginTimeLogger\src).'
}

. $commonError
$null = Initialize-ErrorLog
if (Get-Command Initialize-SmtpAlerts -ErrorAction SilentlyContinue) {
    try { $null = Initialize-SmtpAlerts } catch { }
}
