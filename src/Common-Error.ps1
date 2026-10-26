# Shared verbose error formatting and dual logging for LoginTimeLogger scripts.
# Dot-source this file from install/monitor/helper scripts.
#
# Every error/warning is printed to the screen and appended to a separate file
# under the Administrator profile:
#   <AdministratorProfile>\LoginTimeLogger\errors.log

$script:LoginTimeErrorLogPath = $null

function Get-DefaultAdministratorProfile {
    # Prefer the current interactive/elevated user's profile (e.g. C:\Users\AdminName).
    # Do not require the built-in Administrator account.
    if (-not [string]::IsNullOrWhiteSpace($env:USERPROFILE) -and
        ($env:USERPROFILE -notmatch '\\System32\\config\\systemprofile$')) {
        return $env:USERPROFILE
    }
    if (-not [string]::IsNullOrWhiteSpace($env:USERNAME) -and ($env:USERNAME -ne 'SYSTEM')) {
        return (Join-Path $env:SystemDrive ('Users\{0}' -f $env:USERNAME))
    }
    return (Join-Path $env:SystemDrive 'Users\Administrator')
}

function Get-DefaultErrorLogPath {
    param([string]$AdministratorProfile)

    if ([string]::IsNullOrWhiteSpace($AdministratorProfile)) {
        $AdministratorProfile = Get-DefaultAdministratorProfile
    }
    return (Join-Path $AdministratorProfile 'LoginTimeLogger\errors.log')
}

function Resolve-ErrorLogPathFromConfig {
    param([string]$ConfigPath)

    $adminProfile = Get-DefaultAdministratorProfile
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not [string]::IsNullOrWhiteSpace([string]$raw.AdministratorProfile)) {
                $adminProfile = [string]$raw.AdministratorProfile
            }
        }
        catch {
            # Keep default profile if config cannot be read yet.
        }
    }
    return (Get-DefaultErrorLogPath -AdministratorProfile $adminProfile)
}

function Initialize-ErrorLog {
    [CmdletBinding()]
    param(
        [string]$AdministratorProfile,
        [string]$ConfigPath,
        [string]$ErrorLogPath
    )

    if (-not [string]::IsNullOrWhiteSpace($ErrorLogPath)) {
        $script:LoginTimeErrorLogPath = $ErrorLogPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AdministratorProfile)) {
        $script:LoginTimeErrorLogPath = Get-DefaultErrorLogPath -AdministratorProfile $AdministratorProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
        $script:LoginTimeErrorLogPath = Resolve-ErrorLogPathFromConfig -ConfigPath $ConfigPath
    }
    elseif ([string]::IsNullOrWhiteSpace($script:LoginTimeErrorLogPath)) {
        $script:LoginTimeErrorLogPath = Get-DefaultErrorLogPath
    }

    $dir = Split-Path -Parent $script:LoginTimeErrorLogPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        catch {
            # Directory creation may fail before elevation; Write-ErrorLog will report that.
        }
    }

    return $script:LoginTimeErrorLogPath
}

function Get-ErrorLogPath {
    if ([string]::IsNullOrWhiteSpace($script:LoginTimeErrorLogPath)) {
        $null = Initialize-ErrorLog
    }
    return $script:LoginTimeErrorLogPath
}

function Write-ErrorLogFile {
    param(
        [Parameter(Mandatory)][string]$Text
    )

    $path = Get-ErrorLogPath
    $dir = Split-Path -Parent $path
    try {
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $path -Value $Text -Encoding UTF8
        return $path
    }
    catch {
        $fallbackDir = Join-Path $env:TEMP 'LoginTimeLogger'
        $fallbackPath = Join-Path $fallbackDir 'errors.log'
        try {
            if (-not (Test-Path -LiteralPath $fallbackDir)) {
                New-Item -ItemType Directory -Path $fallbackDir -Force | Out-Null
            }
            $note = @(
                "FAILED to write Administrator error log: $path"
                "Fallback log: $fallbackPath"
                "Write error: $($_.Exception.Message)"
                $Text
            ) -join [Environment]::NewLine
            Add-Content -LiteralPath $fallbackPath -Value $note -Encoding UTF8
            Write-Host ("WARNING: Could not write error log to '{0}'. Wrote fallback: '{1}'" -f $path, $fallbackPath) -ForegroundColor Yellow
            return $fallbackPath
        }
        catch {
            Write-Host ("WARNING: Could not write error log to '{0}' or TEMP fallback. Screen output only. Reason: {1}" -f $path, $_.Exception.Message) -ForegroundColor Yellow
            return $null
        }
    }
}

function Write-ErrorMessage {
    <#
    .SYNOPSIS
      Prints an error/warning to the screen and appends it to the Administrator error log.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Message,

        [ValidateSet('ERROR', 'WARN')]
        [string]$Level = 'ERROR',

        [string]$Source = ''
    )

    if ([string]::IsNullOrWhiteSpace($script:LoginTimeErrorLogPath)) {
        $null = Initialize-ErrorLog
    }

    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $sourcePart = if ([string]::IsNullOrWhiteSpace($Source)) { '' } else { " [$Source]" }
    $header = '{0} [{1}]{2}' -f $stamp, $Level, $sourcePart
    $banner = '---------- ERROR DETAILS ----------'
    $footer = '-----------------------------------'
    $text = "{0}`r`n{1}`r`n{2}`r`n{3}`r`n" -f $banner, $header, $Message, $footer

    if ($Level -eq 'WARN') {
        Write-Host $text -ForegroundColor Yellow
    }
    else {
        Write-Host $text -ForegroundColor Red
    }

    $logPath = Write-ErrorLogFile -Text $text
    if ($logPath) {
        Write-Host ("Error also logged to: {0}" -f $logPath) -ForegroundColor DarkYellow
    }

    return $Message
}

function Format-ErrorDetails {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ErrorRecord,

        [string]$Context = ''
    )

    if ($null -eq $ErrorRecord) {
        return 'ErrorRecord was null.'
    }

    $lines = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($Context)) {
        $lines.Add("Context: $Context")
    }

    $ex = $ErrorRecord.Exception
    if ($null -eq $ex) {
        $lines.Add("Message: $($ErrorRecord.ToString())")
    }
    else {
        $lines.Add("Message: $($ex.Message)")
        $lines.Add("ExceptionType: $($ex.GetType().FullName)")
        try {
            $lines.Add(('HResult: 0x{0:X8}' -f $ex.HResult))
        }
        catch {
            # ignore
        }
        if ($ex -is [System.ComponentModel.Win32Exception]) {
            $lines.Add("NativeErrorCode: $($ex.NativeErrorCode)")
        }
        if ($ex -is [System.IO.IOException] -and $ex.PSObject.Properties['HResult']) {
            $lines.Add("IO HResult: $($ex.HResult)")
        }
    }

    if ($ErrorRecord.FullyQualifiedErrorId) {
        $lines.Add("FullyQualifiedErrorId: $($ErrorRecord.FullyQualifiedErrorId)")
    }
    if ($ErrorRecord.CategoryInfo) {
        $lines.Add("CategoryInfo: $($ErrorRecord.CategoryInfo.ToString())")
    }

    $invocation = $ErrorRecord.InvocationInfo
    if ($null -ne $invocation) {
        if ($invocation.MyCommand) {
            $lines.Add("Command: $($invocation.MyCommand)")
        }
        if ($invocation.ScriptName) {
            $lines.Add("ScriptName: $($invocation.ScriptName)")
        }
        $lines.Add("ScriptLineNumber: $($invocation.ScriptLineNumber)")
        $lines.Add("OffsetInLine: $($invocation.OffsetInLine)")
        if ($invocation.Line) {
            $lines.Add("Code: $($invocation.Line.Trim())")
        }
        if ($invocation.PipelinePosition) {
            $lines.Add("PipelinePosition: $($invocation.PipelinePosition)")
        }
    }

    if ($ErrorRecord.ScriptStackTrace) {
        $lines.Add('ScriptStackTrace:')
        foreach ($stackLine in ($ErrorRecord.ScriptStackTrace -split "`r?`n")) {
            if (-not [string]::IsNullOrWhiteSpace($stackLine)) {
                $lines.Add("  $stackLine")
            }
        }
    }

    $inner = if ($null -ne $ex) { $ex.InnerException } else { $null }
    $depth = 0
    while ($null -ne $inner -and $depth -lt 8) {
        $lines.Add(("InnerException[{0}]: {1}: {2}" -f $depth, $inner.GetType().FullName, $inner.Message))
        try {
            $lines.Add(('  HResult: 0x{0:X8}' -f $inner.HResult))
        }
        catch {
            # ignore
        }
        if ($inner -is [System.ComponentModel.Win32Exception]) {
            $lines.Add("  NativeErrorCode: $($inner.NativeErrorCode)")
        }
        $inner = $inner.InnerException
        $depth++
    }

    if (Get-Variable -Name PSVersionTable -ErrorAction SilentlyContinue) {
        $lines.Add(("PSVersion: {0} ({1})" -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition))
    }
    $lines.Add(("ProcessId: {0}; User: {1}" -f $PID, $env:USERNAME))
    $lines.Add(("TimestampUtc: {0:o}" -f [datetime]::UtcNow))
    $lines.Add(("ErrorLogPath: {0}" -f (Get-ErrorLogPath)))

    return ($lines -join [Environment]::NewLine)
}

function Write-VerboseError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        $ErrorRecord,

        [string]$Context = '',

        [ValidateSet('Error', 'Warning')]
        [string]$Level = 'Error',

        [string]$Source = ''
    )

    $details = Format-ErrorDetails -ErrorRecord $ErrorRecord -Context $Context
    $logLevel = if ($Level -eq 'Warning') { 'WARN' } else { 'ERROR' }
    $null = Write-ErrorMessage -Message $details -Level $logLevel -Source $Source
    return $details
}

function New-VerboseException {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string]$Message,

        [Parameter(Mandatory)]
        $ErrorRecord,

        [string]$Context = ''
    )

    $details = Format-ErrorDetails -ErrorRecord $ErrorRecord -Context $Context
    return (New-Object System.Exception(("{0}`r`n{1}" -f $Message, $details), $ErrorRecord.Exception))
}
