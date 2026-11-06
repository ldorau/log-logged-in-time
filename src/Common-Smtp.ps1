# SMTP alert helper for LoginTimeLogger (dot-source after Common-Error.ps1).
# Settings live in <AdministratorProfile>\LoginTimeLogger\smtp.json
# (admin + SYSTEM ACL only; never in the target-readable config.json).

$script:LoginTimeSmtpConfigPath = $null
$script:LoginTimeSmtpConfig = $null
$script:LoginTimeSmtpCooldownPath = $null

function Get-DefaultSmtpConfigPath {
    param([string]$AdministratorProfile)

    if ([string]::IsNullOrWhiteSpace($AdministratorProfile)) {
        $AdministratorProfile = Get-DefaultAdministratorProfile
    }
    return (Join-Path $AdministratorProfile 'LoginTimeLogger\smtp.json')
}

function Get-SmtpConfigPath {
    if (-not [string]::IsNullOrWhiteSpace($script:LoginTimeSmtpConfigPath)) {
        return $script:LoginTimeSmtpConfigPath
    }
    $errorLog = Get-ErrorLogPath
    if (-not [string]::IsNullOrWhiteSpace($errorLog)) {
        $dir = Split-Path -Parent $errorLog
        return (Join-Path $dir 'smtp.json')
    }
    return (Get-DefaultSmtpConfigPath)
}

function Initialize-SmtpAlerts {
    [CmdletBinding()]
    param(
        [string]$AdministratorProfile,
        [string]$ConfigPath,
        [string]$SmtpConfigPath
    )

    if (-not [string]::IsNullOrWhiteSpace($SmtpConfigPath)) {
        $script:LoginTimeSmtpConfigPath = $SmtpConfigPath
    }
    elseif (-not [string]::IsNullOrWhiteSpace($AdministratorProfile)) {
        $script:LoginTimeSmtpConfigPath = Get-DefaultSmtpConfigPath -AdministratorProfile $AdministratorProfile
    }
    elseif (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
        try {
            $raw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
            $admin = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'AdministratorProfile')
            if ([string]::IsNullOrWhiteSpace($admin)) {
                $admin = Get-DefaultAdministratorProfile
            }
            $script:LoginTimeSmtpConfigPath = Get-DefaultSmtpConfigPath -AdministratorProfile $admin
        }
        catch {
            $script:LoginTimeSmtpConfigPath = Get-DefaultSmtpConfigPath
        }
    }
    else {
        $script:LoginTimeSmtpConfigPath = Get-DefaultSmtpConfigPath
    }

    $smtpDir = Split-Path -Parent $script:LoginTimeSmtpConfigPath
    $script:LoginTimeSmtpCooldownPath = Join-Path $smtpDir 'smtp-alert-cooldown.json'
    $script:LoginTimeSmtpConfig = $null
    return $script:LoginTimeSmtpConfigPath
}

function Read-SmtpAlertConfig {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        $Path = Get-SmtpConfigPath
    }
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }

    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    }
    catch {
        return $null
    }

    # StrictMode-safe: older smtp.json may omit newer keys (e.g. CooldownMinutes).
    $cfgEnabled = Get-OptionalPropertyValue -InputObject $raw -Name 'Enabled'
    $enabled = $false
    if ($null -ne $cfgEnabled) {
        $enabled = [bool]$cfgEnabled
    }
    $port = 587
    $cfgPort = Get-OptionalPropertyValue -InputObject $raw -Name 'SmtpPort'
    if ($null -ne $cfgPort -and [int]$cfgPort -gt 0) {
        $port = [int]$cfgPort
    }
    $useSsl = $true
    $cfgUseSsl = Get-OptionalPropertyValue -InputObject $raw -Name 'UseSsl'
    if ($null -ne $cfgUseSsl) {
        $useSsl = [bool]$cfgUseSsl
    }
    $cooldown = 60
    $cfgCooldown = Get-OptionalPropertyValue -InputObject $raw -Name 'CooldownMinutes'
    if ($null -ne $cfgCooldown -and [int]$cfgCooldown -ge 0) {
        $cooldown = [int]$cfgCooldown
    }

    return [pscustomobject]@{
        Enabled         = $enabled
        SmtpHost        = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'SmtpHost')
        SmtpPort        = $port
        UseSsl          = $useSsl
        From            = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'From')
        To              = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'To')
        Username        = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'Username')
        Password        = [string](Get-OptionalPropertyValue -InputObject $raw -Name 'Password')
        CooldownMinutes = $cooldown
        ConfigPath      = $Path
    }
}

function Test-SmtpAlertConfigured {
    param($SmtpConfig)

    if (-not $SmtpConfig -or -not $SmtpConfig.Enabled) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($SmtpConfig.SmtpHost)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($SmtpConfig.From) -or [string]::IsNullOrWhiteSpace($SmtpConfig.To)) {
        return $false
    }
    if ([string]::IsNullOrWhiteSpace($SmtpConfig.Username) -or [string]::IsNullOrWhiteSpace($SmtpConfig.Password)) {
        return $false
    }
    return $true
}

function Test-SmtpAlertCooldownAllowsSend {
    param(
        [Parameter(Mandatory)][string]$AlertKey,
        [Parameter(Mandatory)][int]$CooldownMinutes,
        [string]$CooldownPath
    )

    if ($CooldownMinutes -le 0) {
        return $true
    }
    if ([string]::IsNullOrWhiteSpace($CooldownPath)) {
        $CooldownPath = $script:LoginTimeSmtpCooldownPath
    }
    if ([string]::IsNullOrWhiteSpace($CooldownPath) -or -not (Test-Path -LiteralPath $CooldownPath)) {
        return $true
    }

    try {
        $raw = Get-Content -LiteralPath $CooldownPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $prop = $raw.PSObject.Properties[$AlertKey]
        if (-not $prop) {
            return $true
        }
        $last = [datetime]::Parse([string]$prop.Value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
        if ($last.Kind -eq [DateTimeKind]::Unspecified) {
            $last = [datetime]::SpecifyKind($last, [DateTimeKind]::Utc)
        }
        return (([datetime]::UtcNow - $last.ToUniversalTime()).TotalMinutes -ge $CooldownMinutes)
    }
    catch {
        return $true
    }
}

function Set-SmtpAlertCooldownStamp {
    param(
        [Parameter(Mandatory)][string]$AlertKey,
        [string]$CooldownPath
    )

    if ([string]::IsNullOrWhiteSpace($CooldownPath)) {
        $CooldownPath = $script:LoginTimeSmtpCooldownPath
    }
    if ([string]::IsNullOrWhiteSpace($CooldownPath)) {
        return
    }

    $map = @{}
    if (Test-Path -LiteralPath $CooldownPath) {
        try {
            $existing = Get-Content -LiteralPath $CooldownPath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($p in $existing.PSObject.Properties) {
                $map[$p.Name] = [string]$p.Value
            }
        }
        catch { }
    }
    $map[$AlertKey] = [datetime]::UtcNow.ToString('o')

    $dir = Split-Path -Parent $CooldownPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    ($map | ConvertTo-Json -Depth 4) | Set-Content -LiteralPath $CooldownPath -Encoding UTF8
}

function Send-LoginTimeSmtpAlert {
    <#
      Sends an email when smtp.json is Enabled and complete.
      Optional -Attachment paths are included when the files exist (size-capped).
      Failures are swallowed (logged to errors.log when possible) so alerts never stop the monitor.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body,
        [string]$AlertKey = '',
        [string]$SmtpConfigPath = '',
        [string[]]$Attachment = @(),
        [int]$MaxAttachmentBytes = 5242880
    )

    try {
        if ([string]::IsNullOrWhiteSpace($script:LoginTimeSmtpConfigPath) -and [string]::IsNullOrWhiteSpace($SmtpConfigPath)) {
            $null = Initialize-SmtpAlerts
        }
        $path = $SmtpConfigPath
        if ([string]::IsNullOrWhiteSpace($path)) {
            $path = Get-SmtpConfigPath
        }

        $cfg = Read-SmtpAlertConfig -Path $path
        if (-not (Test-SmtpAlertConfigured -SmtpConfig $cfg)) {
            return $false
        }

        $key = $AlertKey
        if ([string]::IsNullOrWhiteSpace($key)) {
            $key = ($Subject.ToLowerInvariant() -replace '[^a-z0-9]+', '-').Trim('-')
            if ([string]::IsNullOrWhiteSpace($key)) {
                $key = 'alert'
            }
        }

        if (-not (Test-SmtpAlertCooldownAllowsSend -AlertKey $key -CooldownMinutes ([int]$cfg.CooldownMinutes))) {
            return $false
        }

        $secure = ConvertTo-SecureString -String $cfg.Password -AsPlainText -Force
        $cred = New-Object System.Management.Automation.PSCredential ($cfg.Username, $secure)

        $computer = $env:COMPUTERNAME
        $attachmentNotes = New-Object System.Collections.Generic.List[string]
        $attachmentPaths = New-Object System.Collections.Generic.List[string]
        $seenAttach = @{}
        foreach ($candidate in @($Attachment)) {
            if ([string]::IsNullOrWhiteSpace($candidate)) {
                continue
            }
            if (-not (Test-Path -LiteralPath $candidate)) {
                $attachmentNotes.Add(("missing: {0}" -f $candidate))
                continue
            }
            try {
                $full = [System.IO.Path]::GetFullPath($candidate)
            }
            catch {
                $full = $candidate
            }
            $attachKey = $full.ToLowerInvariant()
            if ($seenAttach.ContainsKey($attachKey)) {
                continue
            }
            $seenAttach[$attachKey] = $true
            $item = Get-Item -LiteralPath $full -ErrorAction SilentlyContinue
            if (-not $item) {
                $attachmentNotes.Add(("missing: {0}" -f $full))
                continue
            }
            if ($item.PSIsContainer) {
                $attachmentNotes.Add(("skipped (not a file): {0}" -f $full))
                continue
            }
            if ($MaxAttachmentBytes -gt 0 -and $item.Length -gt $MaxAttachmentBytes) {
                $attachmentNotes.Add(("skipped (too large {0} bytes): {1}" -f $item.Length, $full))
                continue
            }
            $attachmentPaths.Add($full)
            $attachmentNotes.Add(("attached: {0} ({1} bytes)" -f $full, $item.Length))
        }

        $fullBody = @(
            $Body
            ''
            ('Computer: {0}' -f $computer)
            ('User: {0}' -f $env:USERNAME)
            ('Utc: {0:o}' -f [datetime]::UtcNow)
            ('SmtpConfig: {0}' -f $cfg.ConfigPath)
        )
        if ($attachmentNotes.Count -gt 0) {
            $fullBody += ''
            $fullBody += '--- attachments ---'
            $fullBody += $attachmentNotes
        }
        $fullBodyText = $fullBody -join [Environment]::NewLine
        $fullSubject = '[LoginTimeLogger] {0} ({1})' -f $Subject, $computer

        $mailParams = @{
            SmtpServer  = $cfg.SmtpHost
            Port        = [int]$cfg.SmtpPort
            UseSsl      = $cfg.UseSsl
            Credential  = $cred
            From        = $cfg.From
            To          = $cfg.To
            Subject     = $fullSubject
            Body        = $fullBodyText
            ErrorAction = 'Stop'
        }
        if ($attachmentPaths.Count -gt 0) {
            $mailParams['Attachments'] = @($attachmentPaths)
        }

        Send-MailMessage @mailParams

        Set-SmtpAlertCooldownStamp -AlertKey $key
        return $true
    }
    catch {
        try {
            if (Get-Command Write-ErrorMessage -ErrorAction SilentlyContinue) {
                $null = Write-ErrorMessage -Level WARN -Source 'SmtpAlert' -Message (
                    "SMTP alert failed: $($_.Exception.Message)")
            }
        }
        catch { }
        return $false
    }
}
