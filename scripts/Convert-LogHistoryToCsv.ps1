#Requires -Version 5.1
<#
.SYNOPSIS
  Convert a log-history SQLite database to a semicolon-separated CSV.
.DESCRIPTION
  Reads a Chromium-style History SQLite file (local name: log-history) and
  writes one CSV row per visit joined with its URL record.

  Output columns (separator ';'):
    visit_time_local;url;title;visit_duration;transition;from_visit;
    visit_count;typed_count;hidden;url_id;visit_id

  visit_duration is always HH:MM:SS (from the History visit_duration field).

  Optional local-time range (mutually exclusive):
    -StartDate YYYY-MM-DD  -> visits from that local day onward
    -PreviousDays N        -> last N local calendar days (including today)

  Requires Windows Python 3 with sqlite3 (python3, python, or py -3).
  If none is found, the script tries to install Python via winget (then the
  official silent installer). Failures are written to errors.log and emailed
  when SMTP is configured.
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
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath C:\Users\ldorau\Downloads\logs-inwin\log-history
.EXAMPLE
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath .\log-history -StartDate 2026-11-01
.EXAMPLE
  .\scripts\Convert-LogHistoryToCsv.ps1 -InputPath .\log-history -PreviousDays 7
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

    # Log as WARN here so Common-Error does not auto-email without attachments;
    # Send-ConvertLogHistoryFailureAlert emails once with errors.log attached.
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

function Test-WindowsPythonCommand {
    param([Parameter(Mandatory)][string[]]$Command)

    try {
        $exe = $Command[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue)) {
            return $false
        }
        $prefix = @()
        if ($Command.Length -gt 1) {
            $prefix = @($Command[1..($Command.Length - 1)])
        }
        $out = & $exe @prefix -c "import sqlite3; print('ok')" 2>$null
        return ($LASTEXITCODE -eq 0 -and ("$out").Trim() -eq 'ok')
    }
    catch {
        return $false
    }
}

function Find-WindowsPythonInstallPaths {
    $paths = New-Object System.Collections.Generic.List[string]
    $searchRoots = New-Object System.Collections.Generic.List[string]
    $localPython = Join-Path $env:LOCALAPPDATA 'Programs\Python'
    if (Test-Path -LiteralPath $localPython) {
        $searchRoots.Add($localPython)
    }
    foreach ($pf in @([string]${env:ProgramFiles}, [string]${env:ProgramFiles(x86)})) {
        if (-not [string]::IsNullOrWhiteSpace($pf) -and (Test-Path -LiteralPath $pf)) {
            $searchRoots.Add($pf)
        }
    }

    foreach ($root in $searchRoots) {
        Get-ChildItem -LiteralPath $root -Directory -Filter 'Python*' -ErrorAction SilentlyContinue |
            ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path -LiteralPath $exe) {
                    $paths.Add($exe)
                }
                Get-ChildItem -LiteralPath $_.FullName -Directory -Filter 'Python3*' -ErrorAction SilentlyContinue |
                    ForEach-Object {
                        $nested = Join-Path $_.FullName 'python.exe'
                        if (Test-Path -LiteralPath $nested) {
                            $paths.Add($nested)
                        }
                    }
            }
    }
    return @($paths)
}

function Resolve-WindowsPythonLauncher {
    $candidates = @(
        ,@( 'python3' )
        ,@( 'python' )
        ,@( 'py', '-3' )
    )
    foreach ($c in $candidates) {
        if (Test-WindowsPythonCommand -Command $c) {
            return ,$c
        }
    }

    foreach ($exe in @(Find-WindowsPythonInstallPaths)) {
        if (Test-WindowsPythonCommand -Command @($exe)) {
            return ,@($exe)
        }
    }
    return $null
}

function Update-ProcessPathFromMachineAndUser {
    $machine = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    $user = [Environment]::GetEnvironmentVariable('Path', 'User')
    $parts = @()
    if (-not [string]::IsNullOrWhiteSpace($machine)) { $parts += $machine }
    if (-not [string]::IsNullOrWhiteSpace($user)) { $parts += $user }
    if ($parts.Count -gt 0) {
        $env:Path = ($parts -join ';')
    }
}

function Install-WindowsPython3 {
    <#
      Tries winget first, then the official python.org silent installer.
      Returns $true when a post-install Resolve-WindowsPythonLauncher succeeds.
    #>
    $logLines = New-Object System.Collections.Generic.List[string]
    $logLines.Add('Windows Python 3 not found; attempting install.')

    $winget = Get-Command winget.exe -ErrorAction SilentlyContinue
    if ($winget) {
        $wingetIds = @('Python.Python.3.12', 'Python.Python.3.13', 'Python.Python.3.11')
        foreach ($id in $wingetIds) {
            $logLines.Add(("winget install {0} ..." -f $id))
            Write-Host ("Installing Python via winget ({0})..." -f $id)
            try {
                $wingetArgs = @(
                    'install', '-e', '--id', $id,
                    '--scope', 'user',
                    '--accept-package-agreements',
                    '--accept-source-agreements',
                    '--disable-interactivity'
                )
                $out = & winget.exe @wingetArgs 2>&1 | Out-String
                $logLines.Add(("winget exit={0}" -f $LASTEXITCODE))
                if (-not [string]::IsNullOrWhiteSpace($out)) {
                    $logLines.Add($out.Trim())
                }
            }
            catch {
                $logLines.Add(("winget threw: {0}" -f $_.Exception.Message))
            }

            Update-ProcessPathFromMachineAndUser
            $found = Resolve-WindowsPythonLauncher
            if ($null -ne $found) {
                $logLines.Add(('Python available after winget: {0}' -f ($found -join ' ')))
                Write-Host ($logLines -join [Environment]::NewLine)
                return $true
            }
        }
    }
    else {
        $logLines.Add('winget.exe not found; trying python.org silent installer.')
    }

    # Official installer fallback (per-user, quiet, add to PATH).
    $installerUrl = 'https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe'
    $installerPath = Join-Path $env:TEMP 'python-3.12.8-amd64-login-time-logger.exe'
    try {
        $logLines.Add(("Downloading {0}" -f $installerUrl))
        Write-Host 'Downloading official Python 3.12 installer...'
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $installerUrl -OutFile $installerPath -UseBasicParsing

        $installArgs = @(
            '/quiet',
            'InstallAllUsers=0',
            'PrependPath=1',
            'Include_test=0',
            'Include_launcher=1',
            'SimpleInstall=1'
        )
        $logLines.Add(('Running installer: {0} {1}' -f $installerPath, ($installArgs -join ' ')))
        Write-Host 'Running silent Python installer...'
        $p = Start-Process -FilePath $installerPath -ArgumentList $installArgs -Wait -PassThru
        $logLines.Add(('installer exit={0}' -f $p.ExitCode))
    }
    catch {
        $logLines.Add(('Official installer failed: {0}' -f $_.Exception.Message))
        Write-Host ($logLines -join [Environment]::NewLine) -ForegroundColor Yellow
        return $false
    }
    finally {
        Remove-Item -LiteralPath $installerPath -Force -ErrorAction SilentlyContinue
    }

    Update-ProcessPathFromMachineAndUser
    # Give the shell a moment for PATH / py launcher registration.
    Start-Sleep -Seconds 2
    Update-ProcessPathFromMachineAndUser
    $found = Resolve-WindowsPythonLauncher
    if ($null -ne $found) {
        $logLines.Add(('Python available after installer: {0}' -f ($found -join ' ')))
        Write-Host ($logLines -join [Environment]::NewLine)
        return $true
    }

    $logLines.Add('Python still not resolvable after install attempts.')
    Write-Host ($logLines -join [Environment]::NewLine) -ForegroundColor Yellow
    $null = Write-ErrorMessage -Message ($logLines -join [Environment]::NewLine) -Level WARN -Source 'Convert-LogHistoryToCsv'
    return $false
}

try {
    if (-not (Test-Path -LiteralPath $pyHelper)) {
        Invoke-ConvertFailure -Message ("Python helper missing: {0}" -f $pyHelper)
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

    Write-Host 'Checking for Windows Python 3 (python3 / python / py -3)...'
    $python = Resolve-WindowsPythonLauncher
    if ($null -eq $python) {
        Write-Host 'Windows Python 3 not found.'
        $installed = $false
        try {
            $installed = [bool](Install-WindowsPython3)
        }
        catch {
            Invoke-ConvertFailure -ErrorRecord $_ -Context 'Windows Python 3 install failed'
        }
        if (-not $installed) {
            $failMsg = @(
                'Windows Python 3 with sqlite3 is not installed and automatic install failed.'
                'Tried: winget Python.Python.3.12/3.13/3.11 and the official silent installer.'
                'Install Python 3 manually, then re-run.'
            ) -join [Environment]::NewLine
            Invoke-ConvertFailure -Message $failMsg
        }
        $python = Resolve-WindowsPythonLauncher
        if ($null -eq $python) {
            Invoke-ConvertFailure -Message 'Python install reported success but python3/python/py -3 still unavailable.'
        }
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
    foreach ($p in $python) { $argList.Add($p) }
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
    # Avoid double-email when Invoke-ConvertFailure already alerted and rethrew.
    $msg = [string]$_.Exception.Message
    if ($msg -match 'Convert-LogHistoryToCsv' -or $msg -match 'Python helper missing' -or
        $msg -match 'Windows Python 3' -or $msg -match 'InputPath not found' -or
        $msg -match 'Separator must be' -or $msg -match 'Expected output CSV') {
        throw
    }
    Invoke-ConvertFailure -ErrorRecord $_ -Context 'Convert-LogHistoryToCsv failed'
}
