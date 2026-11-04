# Shared verbose error formatting and dual logging for LoginTimeLogger scripts.
# Dot-source this file from install/monitor/helper scripts.
#
# Every error/warning is printed to the screen and appended to a separate file
# under the Administrator profile:
#   <AdministratorProfile>\LoginTimeLogger\errors.log
#
# ERROR-level messages also attempt an SMTP alert when smtp.json is enabled
# (see Common-Smtp.ps1 beside this file).

$script:LoginTimeErrorLogPath = $null

# Optional SMTP helper (same folder). Missing file is fine for older installs.
$script:LoginTimeSmtpHelperPath = Join-Path $PSScriptRoot 'Common-Smtp.ps1'
if (-not (Test-Path -LiteralPath $script:LoginTimeSmtpHelperPath)) {
    # When dot-sourced via full path, $PSScriptRoot may be empty in PS 5.1.
    if ($MyInvocation.MyCommand.Path) {
        $script:LoginTimeSmtpHelperPath = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'Common-Smtp.ps1'
    }
}
if ((Test-Path -LiteralPath $script:LoginTimeSmtpHelperPath) -and -not (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue)) {
    . $script:LoginTimeSmtpHelperPath
}

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

function Get-OptionalPropertyValue {
    <#
      StrictMode-safe property read. ConvertFrom-Json omits missing keys; under
      Set-StrictMode, $obj.Missing throws PropertyNotFoundStrict.
    #>
    param(
        [AllowNull()]$InputObject,
        [Parameter(Mandatory)][string]$Name
    )
    if ($null -eq $InputObject) {
        return $null
    }
    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -eq $prop) {
        return $null
    }
    return $prop.Value
}

function ConvertTo-UInt32Code {
    <#
      Task Scheduler LastTaskResult is Int32. HRESULTs with the high bit set
      appear negative (e.g. 0x800710E0 -> -2147020576); [uint32] cast throws.
    #>
    param([AllowNull()]$Value)
    if ($null -eq $Value) {
        return [uint32]0
    }
    return [BitConverter]::ToUInt32([BitConverter]::GetBytes([int32]$Value), 0)
}

function ConvertTo-StartProcessArgumentString {
    <#
      Start-Process -ArgumentList with a string[] joins on spaces WITHOUT quoting.
      Paths under "C:\Program Files\..." then break (-File sees C:\Program and
      powershell.exe exits -196608 / 0xFFFD0000). Build one quoted string instead.
    #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Argument)

    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($a in $Argument) {
        if ($null -eq $a) {
            continue
        }
        $s = [string]$a
        if ($s -match '[\s"]') {
            $parts.Add('"' + ($s.Replace('"', '\"')) + '"')
        }
        else {
            $parts.Add($s)
        }
    }
    return ($parts -join ' ')
}

function Invoke-WindowsPowerShellFile {
    <#
      Runs powershell.exe -File <script> with correctly quoted ArgumentList so
      InstallRoot under Program Files works.

      Default: returns the Process object.
      -CaptureOutput: redirects stdout/stderr (Write-Host is included when the
      child has no console) and returns a PSCustomObject with ExitCode/StdOut/StdErr/Output.
    #>
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [string[]]$ScriptArgument = @(),
        [switch]$CaptureOutput
    )

    if (-not (Test-Path -LiteralPath $ScriptPath)) {
        throw ("PowerShell script not found: {0}" -f $ScriptPath)
    }

    $windowsPowerShell = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $argTokens = New-Object System.Collections.Generic.List[string]
    $argTokens.Add('-NoProfile')
    $argTokens.Add('-NonInteractive')
    $argTokens.Add('-ExecutionPolicy')
    $argTokens.Add('Bypass')
    $argTokens.Add('-File')
    $argTokens.Add($ScriptPath)
    foreach ($a in @($ScriptArgument)) {
        if ($null -ne $a) {
            $argTokens.Add([string]$a)
        }
    }

    $argLine = ConvertTo-StartProcessArgumentString -Argument $argTokens.ToArray()

    if (-not $CaptureOutput) {
        return (Start-Process -FilePath $windowsPowerShell -ArgumentList $argLine `
                -Wait -PassThru -WindowStyle Hidden)
    }

    $stamp = [guid]::NewGuid().ToString('N')
    $stdoutFile = Join-Path $env:TEMP ("LoginTimeLogger-ps-out-{0}.txt" -f $stamp)
    $stderrFile = Join-Path $env:TEMP ("LoginTimeLogger-ps-err-{0}.txt" -f $stamp)
    try {
        $proc = Start-Process -FilePath $windowsPowerShell -ArgumentList $argLine `
            -Wait -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutFile `
            -RedirectStandardError $stderrFile

        $stdout = ''
        $stderr = ''
        if (Test-Path -LiteralPath $stdoutFile) {
            $stdout = [string](Get-Content -LiteralPath $stdoutFile -Raw -ErrorAction SilentlyContinue)
        }
        if (Test-Path -LiteralPath $stderrFile) {
            $stderr = [string](Get-Content -LiteralPath $stderrFile -Raw -ErrorAction SilentlyContinue)
        }
        if ($null -eq $stdout) { $stdout = '' }
        if ($null -eq $stderr) { $stderr = '' }

        $exitCode = 0
        if ($null -ne $proc) {
            $exitCode = [int]$proc.ExitCode
        }

        $combined = (($stdout, $stderr | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join [Environment]::NewLine).Trim()
        return [pscustomobject]@{
            ExitCode = $exitCode
            StdOut   = $stdout.TrimEnd()
            StdErr   = $stderr.TrimEnd()
            Output   = $combined
            Process  = $proc
        }
    }
    finally {
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
    }
}

function Limit-TextForAlert {
    <#
      Keeps SMTP bodies readable: prefer the tail when truncating.
    #>
    param(
        [AllowNull()][string]$Text,
        [int]$MaxChars = 12000
    )
    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ''
    }
    $t = $Text.TrimEnd()
    if ($t.Length -le $MaxChars) {
        return $t
    }
    $tail = $t.Substring($t.Length - $MaxChars)
    return ("...[truncated {0} chars]...{1}{2}" -f ($t.Length - $MaxChars), [Environment]::NewLine, $tail)
}

function Get-PowerShellFileExitHint {
    <#
      powershell.exe -File returns -196608 (0xFFFD0000) when the script path cannot
      be loaded (missing file, or Start-Process split an unquoted Program Files path).
    #>
    param(
        [int]$ExitCode,
        [string]$ScriptPath
    )
    if ($ExitCode -ne -196608) {
        return ''
    }
    return (" exit -196608 (0xFFFD0000) usually means -File could not load the script (missing path or unquoted spaces). Script='{0}'." -f $ScriptPath)
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
            $cfgAdmin = Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile'
            if (-not [string]::IsNullOrWhiteSpace([string]$cfgAdmin)) {
                $adminProfile = [string]$cfgAdmin
            }
        }
        catch {
            # Keep default profile if config cannot be read yet.
        }
    }
    return (Get-DefaultErrorLogPath -AdministratorProfile $adminProfile)
}

function Get-LoginTimeLoggerRuntimeConfigPath {
    <#
      Resolves the installed runtime config path from the LoginTimeLogger task
      (-ConfigPath argument). Lets Status/Get-LockedTime run as the target user
      without guessing the admin profile.
    #>
    param([string]$TaskName = 'LoginTimeLogger')

    try {
        $task = Get-ScheduledTask -TaskName $TaskName -ErrorAction Stop
        foreach ($action in @($task.Actions)) {
            $arguments = [string]$action.Arguments
            if ([string]::IsNullOrWhiteSpace($arguments)) {
                continue
            }
            if ($arguments -match '-ConfigPath\s+"([^"]+)"') {
                $path = $Matches[1]
            }
            elseif ($arguments -match "-ConfigPath\s+'([^']+)'") {
                $path = $Matches[1]
            }
            elseif ($arguments -match '-ConfigPath\s+(\S+)') {
                $path = $Matches[1].TrimEnd('"').TrimEnd("'")
            }
            else {
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -LiteralPath $path)) {
                return $path
            }
        }
    }
    catch {
        # Task missing or not queryable; caller falls back.
    }
    return $null
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

    if ($Level -eq 'ERROR' -and $Source -ne 'SmtpAlert' -and (Get-Command Send-LoginTimeSmtpAlert -ErrorAction SilentlyContinue)) {
        $alertSubject = if ([string]::IsNullOrWhiteSpace($Source)) { 'Fatal error' } else { "Fatal error ($Source)" }
        $null = Send-LoginTimeSmtpAlert -Subject $alertSubject -Body $Message -AlertKey ("fatal-{0}" -f $(if ($Source) { $Source } else { 'general' }))
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

function Get-NormalizedProfilePath {
    param([Parameter(Mandatory)][string]$Path)

    $expanded = [Environment]::ExpandEnvironmentVariables($Path.Trim()).TrimEnd('\', '/')
    return $expanded
}

function Test-LooksLikeFilePath {
    param([Parameter(Mandatory)][string]$Value)

    $v = $Value.Trim()
    return ($v -match '^[A-Za-z]:\\' -or $v.StartsWith('\\'))
}

function Get-AccountSamLeaf {
    param([Parameter(Mandatory)][string]$UserName)

    $sam = $UserName.Trim()
    if ($sam -match '^(?<domain>[^\\]+)\\(?<user>.+)$') {
        return $Matches['user']
    }
    if ($sam -match '^(?<user>[^@]+)@') {
        return $Matches['user']
    }
    return $sam
}

function Resolve-SidFromProfilePath {
    <#
    .SYNOPSIS
      Finds the account SID whose ProfileList ProfileImagePath matches the given profile folder.
      Works under SYSTEM when NTAccount name translation fails (Microsoft / Entra accounts).
    #>
    param([Parameter(Mandatory)][string]$ProfilePath)

    $want = Get-NormalizedProfilePath -Path $ProfilePath
    if ([string]::IsNullOrWhiteSpace($want)) {
        return $null
    }

    $profileList = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList'
    if (-not (Test-Path -LiteralPath $profileList)) {
        return $null
    }

    foreach ($key in @(Get-ChildItem -LiteralPath $profileList -ErrorAction SilentlyContinue)) {
        try {
            $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction Stop
            $image = [string]$props.ProfileImagePath
            if ([string]::IsNullOrWhiteSpace($image)) {
                continue
            }
            $have = Get-NormalizedProfilePath -Path $image
            if ([string]::Equals($have, $want, [System.StringComparison]::OrdinalIgnoreCase)) {
                return (New-Object System.Security.Principal.SecurityIdentifier($key.PSChildName))
            }
        }
        catch { }
    }
    return $null
}

function Get-ProfilePathForSid {
    param([Parameter(Mandatory)][System.Security.Principal.SecurityIdentifier]$Sid)

    $keyPath = Join-Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' $Sid.Value
    if (-not (Test-Path -LiteralPath $keyPath)) {
        return $null
    }
    try {
        $image = [string](Get-ItemProperty -LiteralPath $keyPath -ErrorAction Stop).ProfileImagePath
        if ([string]::IsNullOrWhiteSpace($image)) {
            return $null
        }
        return (Get-NormalizedProfilePath -Path $image)
    }
    catch {
        return $null
    }
}

function Resolve-WindowsAccountSid {
    <#
    .SYNOPSIS
      Resolves a Windows account to a SID for ACLs.
      Accepts: user | DOMAIN\user | user@upn | .\user | profile path (C:\Users\...).
      Falls back to ProfileList when NTAccount translation fails.
    #>
    param(
        [Parameter(Mandatory)][string]$UserName,
        [string]$ProfilePath = ''
    )

    $trimmed = $UserName.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmed)) {
        return $null
    }

    if (Test-LooksLikeFilePath -Value $trimmed) {
        $sidFromPath = Resolve-SidFromProfilePath -ProfilePath $trimmed
        if ($sidFromPath) {
            return $sidFromPath
        }
    }

    $candidates = New-Object System.Collections.Generic.List[string]
    $candidates.Add($trimmed)

    $sam = Get-AccountSamLeaf -UserName $trimmed
    if ($sam -ne $trimmed -and -not (Test-LooksLikeFilePath -Value $trimmed)) {
        $candidates.Add($sam)
    }
    if ($sam -notmatch '[\\@]' -and -not (Test-LooksLikeFilePath -Value $sam)) {
        # Prefer concatenation over -f inside .Add(...): PowerShell parses
        # Add(fmt -f a, b) as Add((fmt -f a), b), which breaks {1} placeholders.
        $candidates.Add('.\' + $sam)
        if (-not [string]::IsNullOrWhiteSpace($env:COMPUTERNAME)) {
            $candidates.Add($env:COMPUTERNAME + '\' + $sam)
        }
        if (-not [string]::IsNullOrWhiteSpace($env:USERDOMAIN)) {
            $candidates.Add($env:USERDOMAIN + '\' + $sam)
        }
        if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) {
            $candidates.Add($env:USERDNSDOMAIN + '\' + $sam)
        }
    }

    foreach ($name in $candidates) {
        try {
            $ntAccount = New-Object System.Security.Principal.NTAccount($name)
            return $ntAccount.Translate([System.Security.Principal.SecurityIdentifier])
        }
        catch { }
    }

    $profileCandidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ProfilePath)) {
        $profileCandidates.Add($ProfilePath)
    }
    if (-not (Test-LooksLikeFilePath -Value $trimmed) -and -not [string]::IsNullOrWhiteSpace($sam)) {
        $profileCandidates.Add((Join-Path $env:SystemDrive ('Users\{0}' -f $sam)))
    }
    foreach ($p in $profileCandidates) {
        $sid = Resolve-SidFromProfilePath -ProfilePath $p
        if ($sid) {
            return $sid
        }
    }

    return $null
}
