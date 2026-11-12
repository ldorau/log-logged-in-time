#Requires -Version 5.1
<#
.SYNOPSIS
  Convert unlocked-time day logs and summary CSV from old format to current.
.DESCRIPTION
  Updates files matching unlocked-time* under a directory (or a single file):

    Day logs (unlocked-time-YYYY-MM-DD.log)
      Old: ... | HEARTBEAT | unlocked=True|False | cumulative_today=HH:MM:SS
      New: ... | HEARTBEAT | cumulative_today=HH:MM:SS | unlocked=True|False

    Summary (unlocked-time-summary.csv)
      UnlockedHours rewritten from UnlockedSeconds as HH:MM:SS
      (also repairs locale-broken rows where a comma split UnlockedHours).

  Already-converted lines/files are left unchanged (idempotent).
.PARAMETER Path
  Directory containing unlocked-time* files, or a single .log/.csv file.
.PARAMETER WhatIf
  Show what would change without writing.
.EXAMPLE
  .\scripts\Convert-UnlockedTimeLogs.ps1 -Path C:\Users\dluka\LoginTimeLogs
.EXAMPLE
  .\scripts\Convert-UnlockedTimeLogs.ps1 -Path \\wsl$\...\logs-inwin -WhatIf
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)]
    [string]$Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Format-UnlockedDuration {
    param([Parameter(Mandatory)][double]$Seconds)
    $ts = [TimeSpan]::FromSeconds([Math]::Max(0, [Math]::Floor($Seconds)))
    '{0:00}:{1:00}:{2:00}' -f [int][Math]::Floor($ts.TotalHours), $ts.Minutes, $ts.Seconds
}

function Convert-UnlockedTimeDayLogText {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $changed = $false
    $outLines = New-Object System.Collections.Generic.List[string]
    # Do not pass a count to -split: PowerShell treats -1 as max-substrings=1.
    $hadTrailingNewline = $normalized.EndsWith("`n")
    $lines = @($normalized -split "`n")
    if ($hadTrailingNewline -and $lines.Count -gt 0 -and [string]::IsNullOrEmpty($lines[$lines.Count - 1])) {
        $lines = @($lines[0..($lines.Count - 2)])
    }
    foreach ($line in $lines) {
        if ($line -match '^(?<prefix>.*\|\s*HEARTBEAT\s*\|\s*)unlocked=(?<u>True|False)\s*\|\s*cumulative_today=(?<c>\d+:\d{2}:\d{2})\s*$') {
            $newLine = '{0}cumulative_today={1} | unlocked={2}' -f $Matches['prefix'], $Matches['c'], $Matches['u']
            $outLines.Add($newLine)
            $changed = $true
        }
        else {
            $outLines.Add($line)
        }
    }
    $joined = ($outLines -join "`n")
    if ($outLines.Count -gt 0 -or $hadTrailingNewline) {
        $joined += "`n"
    }
    return [pscustomobject]@{
        Text    = $joined
        Changed = $changed
    }
}

function Convert-UnlockedTimeSummaryText {
    param([Parameter(Mandatory)][string]$Text)

    $normalized = $Text -replace "`r`n", "`n" -replace "`r", "`n"
    $header = 'Date,UnlockedSeconds,UnlockedHours,TargetUsername'
    $inv = [System.Globalization.CultureInfo]::InvariantCulture
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add($header)
    $changed = $false
    $seenDate = @{}

    foreach ($line in ($normalized -split "`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $trim = $line.Trim().TrimStart([char]0xFEFF)
        if ($trim -match '^\s*Date\s*,') {
            if (-not [string]::Equals($trim, $header, [System.StringComparison]::Ordinal)) {
                $changed = $true
            }
            continue
        }

        $parts = @($trim.Split(','))
        $date = ''
        $seconds = $null
        $user = ''

        if ($parts.Count -eq 4 -and $parts[0] -match '^\d{4}-\d{2}-\d{2}$') {
            $date = $parts[0]
            $secParsed = 0.0
            if (-not [double]::TryParse($parts[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$secParsed)) {
                $out.Add($trim)
                continue
            }
            $seconds = $secParsed
            $user = $parts[3]
        }
        elseif ($parts.Count -ge 5 -and $parts[0] -match '^\d{4}-\d{2}-\d{2}$') {
            $date = $parts[0]
            $secParsed = 0.0
            if (-not [double]::TryParse($parts[1], [System.Globalization.NumberStyles]::Float, $inv, [ref]$secParsed)) {
                $changed = $true
                continue
            }
            $seconds = $secParsed
            $user = $parts[$parts.Count - 1]
            $changed = $true
        }
        else {
            $out.Add($trim)
            continue
        }

        if ($seenDate.ContainsKey($date)) {
            $changed = $true
            continue
        }
        $seenDate[$date] = $true

        $hoursText = Format-UnlockedDuration -Seconds ([double]$seconds)
        $row = [string]::Format($inv, '{0},{1:F0},{2},{3}', $date, $seconds, $hoursText, $user)
        if (-not [string]::Equals($trim, $row, [System.StringComparison]::Ordinal)) {
            $changed = $true
        }
        $out.Add($row)
    }

    $joined = ($out -join "`n")
    if ($out.Count -gt 0) {
        $joined += "`n"
    }
    return [pscustomobject]@{
        Text    = $joined
        Changed = $changed
    }
}

function Write-Utf8NoBomFile {
    param(
        [Parameter(Mandatory)][string]$LiteralPath,
        [Parameter(Mandatory)][string]$Text
    )
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($LiteralPath, $Text, $utf8)
}

if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
    throw ("Path not found: {0}" -f $Path)
}

$item = Get-Item -LiteralPath $Path -Force
$files = New-Object System.Collections.Generic.List[System.IO.FileInfo]
if ($item.PSIsContainer) {
    Get-ChildItem -LiteralPath $item.FullName -File -Force |
        Where-Object { $_.Name -like 'unlocked-time*' -and ($_.Extension -in @('.log', '.csv')) } |
        Sort-Object Name |
        ForEach-Object { $files.Add($_) }
}
else {
    if ($item.Name -notlike 'unlocked-time*') {
        throw ("File name must match unlocked-time*: {0}" -f $item.FullName)
    }
    $files.Add($item)
}

if ($files.Count -eq 0) {
    Write-Host ("No unlocked-time* .log/.csv files under '{0}'." -f $item.FullName)
    exit 0
}

$converted = 0
$skipped = 0
foreach ($f in $files) {
    $rawBytes = [System.IO.File]::ReadAllBytes($f.FullName)
    $utf8 = New-Object System.Text.UTF8Encoding($false)
    $text = $utf8.GetString($rawBytes)
    if ($rawBytes.Length -ge 3 -and $rawBytes[0] -eq 0xEF -and $rawBytes[1] -eq 0xBB -and $rawBytes[2] -eq 0xBF) {
        $text = $utf8.GetString($rawBytes, 3, $rawBytes.Length - 3)
    }

    if ($f.Extension -eq '.csv' -or $f.Name -like '*summary*') {
        $result = Convert-UnlockedTimeSummaryText -Text $text
        $kind = 'summary'
    }
    else {
        $result = Convert-UnlockedTimeDayLogText -Text $text
        $kind = 'day-log'
    }

    if (-not $result.Changed) {
        Write-Host ("[skip] {0} ({1}, already current)" -f $f.Name, $kind)
        $skipped++
        continue
    }

    if ($PSCmdlet.ShouldProcess($f.FullName, "Convert $kind to current unlocked-time format")) {
        Write-Utf8NoBomFile -LiteralPath $f.FullName -Text ([string]$result.Text)
        Write-Host ("[ok]   {0} ({1})" -f $f.Name, $kind)
        $converted++
    }
    else {
        Write-Host ("[whatif] {0} ({1})" -f $f.Name, $kind)
        $converted++
    }
}

Write-Host ("Done. converted={0}; skipped={1}; total={2}" -f $converted, $skipped, $files.Count)
