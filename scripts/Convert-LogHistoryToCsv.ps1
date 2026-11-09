#Requires -Version 5.1
<#
.SYNOPSIS
  Convert a log-history SQLite database to a semicolon-separated CSV.
.DESCRIPTION
  Reads a browser History SQLite file (e.g. log-history-op / log-history-ch)
  and writes one CSV row per visit joined with its URL record.

  Output columns (separator ';'):
    visit_time_local;url;title;visit_duration;transition;from_visit;
    visit_count;typed_count;hidden;url_id;visit_id

  visit_duration is always HH:MM:SS (from the History visit_duration field).

  Optional local-time range (mutually exclusive):
    -StartDate YYYY-MM-DD  -> visits from that local day onward
    -PreviousDays N        -> last N local calendar days (including today)

  Requires Windows Python 3 with sqlite3. Uses Ensure-WindowsPython3.ps1 to
  check/install it. Failures are written to errors.log and emailed when SMTP
  is configured.
.PARAMETER InputPath
  Path to the log-history SQLite file.
.PARAMETER OutputPath
  Destination CSV path. Default: <InputPath>.csv
.PARAMETER Separator
  CSV field separator. Default: ;
.PARAMETER StartDate
  Local calendar day to start from (inclusive), format YYYY-MM-DD.
.PARAMETER PreviousDays
  Number of local calendar days to include, counting back from today.
.PARAMETER ConfigPath
  Optional LoginTimeLogger config.json (for error-log / SMTP location).
.PARAMETER SmtpConfigPath
  Optional smtp.json path override.
.EXAMPLE
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath C:\Users\ldorau\Downloads\logs-inwin\log-history-op
.EXAMPLE
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath .\log-history-op -StartDate 2026-11-01
.EXAMPLE
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath .\log-history-ch -PreviousDays 7
#>
[CmdletBinding(DefaultParameterSetName = 'All')]
param(
    [Parameter(Mandatory)]
    [string]$InputPath,

    [string]$OutputPath = '',

    [string]$Separator = ';',

    [Parameter(Mandatory, ParameterSetName = 'StartDate')]
    [ValidatePattern('^\d{4}-\d{2}-\d{2}$')]
    [string]$StartDate,

    [Parameter(Mandatory, ParameterSetName = 'PreviousDays')]
    [ValidateRange(1, 36500)]
    [int]$PreviousDays,

    [string]$ConfigPath = '',

    [string]$SmtpConfigPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir
$pyHelper = Join-Path $scriptDir 'Convert-LogHistoryToCsv.py'
$ensurePython = Join-Path $scriptDir 'Ensure-WindowsPython3.ps1'

$commonErrorPath = Join-Path $repoRoot 'src\Common-Error.ps1'
if (-not (Test-Path -LiteralPath $commonErrorPath)) {
    throw ("Shared error helper missing: {0}" -f $commonErrorPath)
}
. $commonErrorPath

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
    $candidates = @(
        (Join-Path $env:USERPROFILE 'LoginTimeLogger\config.json')
        (Join-Path $repoRoot 'config\config.json')
    )
    foreach ($c in $candidates) {
        if (Test-Path -LiteralPath $c) {
            $ConfigPath = $c
            break
        }
    }
}

$null = Initialize-ErrorLog -ConfigPath $ConfigPath
if (Get-Command Initialize-SmtpAlerts -ErrorAction SilentlyContinue) {
    $null = Initialize-SmtpAlerts -ConfigPath $ConfigPath -SmtpConfigPath $SmtpConfigPath
}

function Send-ConvertLogHistoryFailureAlert {
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body
    )

    $attachments = New-Object System.Collections.Generic.List[string]
    try {
        $errLog = Get-ErrorLogPath
        if (-not [string]::IsNullOrWhiteSpace($errLog) -and (Test-Path -LiteralPath $errLog)) {
            $attachments.Add($errLog)
        }
    }
    catch { }

    if (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue) {
        $null = Send-LoginTimeSmtpAlert `
            -Subject $Subject `
            -Body $Body `
            -AlertKey 'convert-log-history-csv' `
            -Attachment @($attachments)
    }
}

function Invoke-ConvertFailure {
    param(
        [Parameter(Mandatory)][string]$Message,
        $ErrorRecord = $null,
        [string]$Context = 'Convert-LogHistoryToCsv failed'
    )

    $details = $Message
    if ($null -ne $ErrorRecord) {
        $details = Format-ErrorDetails -ErrorRecord $ErrorRecord -Context $Context
    }
    else {
        $details = "{0}`r`n{1}" -f $Context, $Message
    }
    $null = Write-ErrorMessage -Message $details -Level WARN -Source 'Convert-LogHistoryToCsv'
    Send-ConvertLogHistoryFailureAlert -Subject 'Convert-LogHistoryToCsv failed' -Body $details
    throw $details
}

try {
    if (-not (Test-Path -LiteralPath $pyHelper)) {
        Invoke-ConvertFailure -Message ("Python helper missing: {0}" -f $pyHelper)
    }
    if (-not (Test-Path -LiteralPath $ensurePython)) {
        Invoke-ConvertFailure -Message ("Ensure-WindowsPython3.ps1 missing: {0}" -f $ensurePython)
    }

    if ([string]::IsNullOrWhiteSpace($InputPath) -or -not (Test-Path -LiteralPath $InputPath)) {
        Invoke-ConvertFailure -Message ("InputPath not found: {0}" -f $InputPath)
    }
    $inputFull = (Get-Item -LiteralPath $InputPath -Force).FullName

    if ([string]::IsNullOrWhiteSpace($OutputPath)) {
        $OutputPath = "$inputFull.csv"
    }
    elseif (-not [System.IO.Path]::IsPathRooted($OutputPath)) {
        $OutputPath = Join-Path (Get-Location).Path $OutputPath
    }

    if ([string]::IsNullOrWhiteSpace($Separator)) {
        $Separator = ';'
    }
    if ($Separator.Length -ne 1) {
        Invoke-ConvertFailure -Message 'Separator must be a single character.'
    }

    $python = $null
    try {
        $python = @( & $ensurePython -ConfigPath $ConfigPath -SmtpConfigPath $SmtpConfigPath -PassThru )
    }
    catch {
        Invoke-ConvertFailure -ErrorRecord $_ -Context 'Ensure-WindowsPython3 failed'
    }
    if ($LASTEXITCODE -ne 0 -or $null -eq $python -or $python.Count -eq 0) {
        Invoke-ConvertFailure -Message 'Ensure-WindowsPython3.ps1 did not return a usable Python launcher.'
    }

    Write-Host ("Input : {0}" -f $inputFull)
    Write-Host ("Output: {0}" -f $OutputPath)
    Write-Host ("Sep   : {0}" -f $Separator)
    Write-Host ("Python: {0}" -f ($python -join ' '))
    if ($PSCmdlet.ParameterSetName -eq 'StartDate') {
        Write-Host ("Range : from {0} local onward" -f $StartDate)
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'PreviousDays') {
        Write-Host ("Range : previous {0} local day(s) including today" -f $PreviousDays)
    }
    else {
        Write-Host 'Range : all visits'
    }

    $argList = New-Object System.Collections.Generic.List[string]
    foreach ($p in $python) { $argList.Add([string]$p) }
    $argList.Add($pyHelper)
    $argList.Add('--input')
    $argList.Add($inputFull)
    $argList.Add('--output')
    $argList.Add($OutputPath)
    $argList.Add('--separator')
    $argList.Add($Separator)
    if ($PSCmdlet.ParameterSetName -eq 'StartDate') {
        $argList.Add('--start-date')
        $argList.Add($StartDate)
    }
    elseif ($PSCmdlet.ParameterSetName -eq 'PreviousDays') {
        $argList.Add('--previous-days')
        $argList.Add([string]$PreviousDays)
    }

    $exe = $argList[0]
    $exeArgs = @($argList | Select-Object -Skip 1)
    & $exe @exeArgs
    if ($LASTEXITCODE -ne 0) {
        Invoke-ConvertFailure -Message ("Convert-LogHistoryToCsv.py failed with exit code {0}" -f $LASTEXITCODE)
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        Invoke-ConvertFailure -Message ("Expected output CSV was not created: {0}" -f $OutputPath)
    }

    Write-Host ("Done: {0}" -f $OutputPath)
}
catch {
    $msg = [string]$_.Exception.Message
    if ($msg -match 'Convert-LogHistoryToCsv' -or $msg -match 'Python helper missing' -or
        $msg -match 'Ensure-WindowsPython3' -or $msg -match 'InputPath not found' -or
        $msg -match 'Separator must be' -or $msg -match 'Expected output CSV') {
        throw
    }
    Invoke-ConvertFailure -ErrorRecord $_ -Context 'Convert-LogHistoryToCsv failed'
}
