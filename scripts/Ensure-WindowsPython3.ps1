#Requires -Version 5.1
<#
.SYNOPSIS
  Ensure Windows Python 3 with sqlite3 is available (install if missing).
.DESCRIPTION
  Checks for python3, python, or py -3 with import sqlite3. If none work,
  tries winget (Python.Python.3.12/3.13/3.11) then the official silent
  installer. Failures are written to errors.log and emailed when SMTP is
  configured (errors.log attached).

  Exit codes:
    0 - Python 3 with sqlite3 is available
    1 - check/install failed
.PARAMETER ConfigPath
  Optional LoginTimeLogger config.json (error-log / SMTP location).
.PARAMETER SmtpConfigPath
  Optional smtp.json path override.
.PARAMETER PassThru
  Emit the resolved launcher as a string[] (e.g. python / py -3 / full path).
.EXAMPLE
  .\scripts\Ensure-WindowsPython3.ps1
.EXAMPLE
  $py = .\scripts\Ensure-WindowsPython3.ps1 -PassThru
#>
[CmdletBinding()]
param(
    [string]$ConfigPath = '',

    [string]$SmtpConfigPath = '',

    [switch]$PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $scriptDir

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

function Send-EnsurePythonFailureAlert {
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
            -AlertKey 'ensure-windows-python3' `
            -Attachment @($attachments)
    }
}

function Invoke-EnsurePythonFailure {
    param(
        [Parameter(Mandatory)][string]$Message,
        $ErrorRecord = $null,
        [string]$Context = 'Ensure-WindowsPython3 failed'
    )

    $details = $Message
    if ($null -ne $ErrorRecord) {
        $details = Format-ErrorDetails -ErrorRecord $ErrorRecord -Context $Context
    }
    else {
        $details = "{0}`r`n{1}" -f $Context, $Message
    }
    # WARN so Common-Error does not auto-email without attachments.
    $null = Write-ErrorMessage -Message $details -Level WARN -Source 'Ensure-WindowsPython3'
    Send-EnsurePythonFailureAlert -Subject 'Ensure-WindowsPython3 failed' -Body $details
    throw $details
}

function Test-WindowsPythonCommand {
    param([Parameter(Mandatory)][string[]]$Command)

    try {
        $exe = $Command[0]
        if (-not (Get-Command $exe -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $exe)) {
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
    $null = Write-ErrorMessage -Message ($logLines -join [Environment]::NewLine) -Level WARN -Source 'Ensure-WindowsPython3'
    return $false
}

try {
    Write-Host 'Checking for Windows Python 3 (python3 / python / py -3)...'
    $python = Resolve-WindowsPythonLauncher
    if ($null -eq $python) {
        Write-Host 'Windows Python 3 not found.'
        $installed = $false
        try {
            $installed = [bool](Install-WindowsPython3)
        }
        catch {
            Invoke-EnsurePythonFailure -ErrorRecord $_ -Context 'Windows Python 3 install failed'
        }
        if (-not $installed) {
            $failMsg = @(
                'Windows Python 3 with sqlite3 is not installed and automatic install failed.'
                'Tried: winget Python.Python.3.12/3.13/3.11 and the official silent installer.'
                'Install Python 3 manually, then re-run.'
            ) -join [Environment]::NewLine
            Invoke-EnsurePythonFailure -Message $failMsg
        }
        $python = Resolve-WindowsPythonLauncher
        if ($null -eq $python) {
            Invoke-EnsurePythonFailure -Message 'Python install reported success but python3/python/py -3 still unavailable.'
        }
    }

    Write-Host ("OK: Windows Python 3 available ({0})" -f ($python -join ' '))
    if ($PassThru) {
        ,$python
    }
    exit 0
}
catch {
    $msg = [string]$_.Exception.Message
    if ($msg -match 'Ensure-WindowsPython3' -or $msg -match 'Windows Python 3') {
        Write-Host $msg -ForegroundColor Red
        exit 1
    }
    try {
        Invoke-EnsurePythonFailure -ErrorRecord $_ -Context 'Ensure-WindowsPython3 failed'
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
    exit 1
}
