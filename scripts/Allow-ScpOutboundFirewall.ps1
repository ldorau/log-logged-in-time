#Requires -Version 5.1
<#
.SYNOPSIS
  Ensures Windows Firewall allows outbound SCP/SSH (TCP) to a remote host.
.DESCRIPTION
  Creates or reconciles outbound Allow rules for TCP to RemoteHost:RemotePort
  (default port 22). Managed rules use the "SCP-Allow:" display-name prefix.

  Host/port can be passed explicitly or loaded from a LoginTimeLogger runtime
  config (ScpHost / ScpPort) via -ConfigPath.

.PARAMETER RemoteHost
  Destination host or IPv4/IPv6 address for SCP.
.PARAMETER RemotePort
  Destination TCP port (default 22, or ScpPort from config).
.PARAMETER ConfigPath
  Runtime config JSON. When RemoteHost is empty, reads ScpHost/ScpPort from here.
.PARAMETER Remove
  Deletes all rules with the SCP-Allow: prefix. Cannot combine with -Verify.
.PARAMETER Verify
  Checks that the expected allow rule exists and filters match. Exit 0 = OK, 1 = FAIL.
.PARAMETER Quiet
  With -Verify, suppress detail output (exit code only).
.EXAMPLE
  .\Allow-ScpOutboundFirewall.ps1 -RemoteHost 10.0.0.10 -RemotePort 22
.EXAMPLE
  .\Allow-ScpOutboundFirewall.ps1 -ConfigPath "$env:USERPROFILE\LoginTimeLogger\config.json"
.EXAMPLE
  .\Allow-ScpOutboundFirewall.ps1 -ConfigPath $cfg -Verify -Quiet
.EXAMPLE
  .\Allow-ScpOutboundFirewall.ps1 -Remove
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$RemoteHost = '',
    [int]$RemotePort = 0,
    [string]$ConfigPath = '',
    [switch]$Remove,
    [switch]$Verify,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'SCP-Allow:'

if ($Remove -and $Verify) {
    throw 'Specify only one of -Remove or -Verify (not both).'
}

function Write-ScpAllowHost {
    param(
        [AllowEmptyString()][string]$Message = '',
        [ConsoleColor]$ForegroundColor
    )
    if ($Quiet) {
        return
    }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $Message
    }
}

function Resolve-ScpTargetFromConfig {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    # Avoid StrictMode PropertyNotFoundStrict when older configs omit SCP keys.
    $hostProp = $raw.PSObject.Properties['ScpHost']
    $hostName = if ($null -ne $hostProp) { [string]$hostProp.Value } else { '' }
    $port = 22
    $portProp = $raw.PSObject.Properties['ScpPort']
    if ($null -ne $portProp -and $null -ne $portProp.Value -and [int]$portProp.Value -gt 0) {
        $port = [int]$portProp.Value
    }
    $enabled = $false
    $enabledProp = $raw.PSObject.Properties['ScpOnLockEnabled']
    if ($null -ne $enabledProp -and $null -ne $enabledProp.Value) {
        $enabled = [bool]$enabledProp.Value
    }
    # Periodic BHistory SCP is always on when ScpHost is configured.
    if (-not $enabled -and -not [string]::IsNullOrWhiteSpace($hostName)) {
        $enabled = $true
    }
    return [pscustomobject]@{
        Host    = $hostName
        Port    = $port
        Enabled = $enabled
    }
}

$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Verify -and -not $isAdmin) {
    Write-Error 'This script must be run from an elevated (Administrator) PowerShell prompt (except -Verify).'
    exit 1
}

if (-not (Get-Module -ListAvailable -Name NetSecurity)) {
    throw 'NetSecurity module is required (Get/New/Remove-NetFirewallRule).'
}
Import-Module NetSecurity -ErrorAction Stop

if ($Remove) {
    Write-ScpAllowHost ("Removing firewall rules with prefix '{0}'..." -f $RulePrefix) -ForegroundColor Yellow
    $existing = @(Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue)
    if ($existing.Count -eq 0) {
        Write-ScpAllowHost 'No matching rules found.' -ForegroundColor Green
        exit 0
    }
    if ($PSCmdlet.ShouldProcess(("$($existing.Count) SCP-Allow rule(s)"), 'Remove firewall rules')) {
        $existing | Remove-NetFirewallRule
        Write-ScpAllowHost ("Removed {0} rule(s)." -f $existing.Count) -ForegroundColor Green
    }
    exit 0
}

# Resolve host/port from parameters and/or config.
if ([string]::IsNullOrWhiteSpace($RemoteHost) -or $RemotePort -le 0) {
    $fromConfig = Resolve-ScpTargetFromConfig -Path $ConfigPath
    if ($fromConfig) {
        if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
            $RemoteHost = [string]$fromConfig.Host
        }
        if ($RemotePort -le 0) {
            $RemotePort = [int]$fromConfig.Port
        }
    }
}
if ($RemotePort -le 0) {
    $RemotePort = 22
}

if ([string]::IsNullOrWhiteSpace($RemoteHost)) {
    throw 'RemoteHost is required (pass -RemoteHost or a -ConfigPath with ScpHost set).'
}

$ruleName = '{0} TCP/{1} to {2}' -f $RulePrefix, $RemotePort, $RemoteHost

function Test-ScpAllowRuleMatches {
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)][string]$ExpectedHost,
        [Parameter(Mandatory)][int]$ExpectedPort
    )

    if ($Rule.Enabled -ne 'True' -or $Rule.Action -ne 'Allow' -or $Rule.Direction -ne 'Outbound') {
        return [pscustomobject]@{ Ok = $false; Reason = 'Enabled/Action/Direction mismatch' }
    }

    try {
        $addrFilter = $Rule | Get-NetFirewallAddressFilter -ErrorAction Stop
        $actual = @($addrFilter.RemoteAddress | ForEach-Object { [string]$_ } |
                Where-Object { $_ -and ($_ -ne 'Any') } |
                ForEach-Object { $_.Trim().ToLowerInvariant() } |
                Sort-Object -Unique)
        $expected = @($ExpectedHost.Trim().ToLowerInvariant())
        if (($actual -join ',') -ne ($expected -join ',')) {
            return [pscustomobject]@{
                Ok     = $false
                Reason = ("RemoteAddress mismatch (got {0})" -f ($actual -join ','))
            }
        }

        $portFilter = $Rule | Get-NetFirewallPortFilter -ErrorAction Stop
        $protoOk = [string]$portFilter.Protocol -eq 'TCP'
        $portOk = @($portFilter.RemotePort | ForEach-Object { [string]$_ }) -contains [string]$ExpectedPort
        if (-not $protoOk -or -not $portOk) {
            return [pscustomobject]@{
                Ok     = $false
                Reason = ("Port/Protocol mismatch (got {0}/{1})" -f $portFilter.Protocol, ($portFilter.RemotePort -join ','))
            }
        }
    }
    catch {
        return [pscustomobject]@{ Ok = $false; Reason = $_.Exception.Message }
    }

    return [pscustomobject]@{ Ok = $true; Reason = '' }
}

if ($Verify) {
    Write-ScpAllowHost '=== SCP-Allow verification ===' -ForegroundColor Cyan
    $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
    if (-not $rule) {
        Write-ScpAllowHost ("FAIL: rule missing: {0}" -f $ruleName) -ForegroundColor Red
        exit 1
    }
    $match = Test-ScpAllowRuleMatches -Rule $rule -ExpectedHost $RemoteHost -ExpectedPort $RemotePort
    if (-not $match.Ok) {
        Write-ScpAllowHost ("FAIL: {0} - {1}" -f $ruleName, $match.Reason) -ForegroundColor Red
        exit 1
    }
    Write-ScpAllowHost ("OK: {0}" -f $ruleName) -ForegroundColor Green
    exit 0
}

# Add / reconcile
Write-ScpAllowHost ("Ensuring outbound Allow for SCP/SSH to {0}:{1}..." -f $RemoteHost, $RemotePort) -ForegroundColor Cyan

$existing = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue
if ($existing) {
    $match = Test-ScpAllowRuleMatches -Rule $existing -ExpectedHost $RemoteHost -ExpectedPort $RemotePort
    if ($match.Ok) {
        Write-ScpAllowHost ("  [ok]     {0}" -f $ruleName) -ForegroundColor DarkGray
        # Drop orphans for other hosts/ports under the same prefix (config changed).
        $orphans = @(Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -ne $ruleName })
        foreach ($orphan in $orphans) {
            if ($PSCmdlet.ShouldProcess($orphan.DisplayName, 'Remove orphan SCP-Allow rule')) {
                $orphan | Remove-NetFirewallRule -ErrorAction Stop
                Write-ScpAllowHost ("  [orphan] removed {0}" -f $orphan.DisplayName) -ForegroundColor Yellow
            }
        }
        Write-ScpAllowHost 'Done.' -ForegroundColor Cyan
        exit 0
    }

    if ($PSCmdlet.ShouldProcess($ruleName, 'Recreate allow firewall rule')) {
        $existing | Remove-NetFirewallRule -ErrorAction Stop
    }
    else {
        exit 0
    }
}
elseif (-not $PSCmdlet.ShouldProcess($ruleName, 'Create outbound allow firewall rule')) {
    exit 0
}

New-NetFirewallRule `
    -DisplayName $ruleName `
    -Description ("Allows outbound SCP/SSH TCP/{0} to {1} (managed by Allow-ScpOutboundFirewall.ps1)" -f $RemotePort, $RemoteHost) `
    -Direction Outbound `
    -Action Allow `
    -Protocol TCP `
    -RemotePort $RemotePort `
    -RemoteAddress $RemoteHost `
    -Profile Any `
    -Enabled True `
    -ErrorAction Stop `
    | Out-Null

Write-ScpAllowHost ("  [added]  {0}" -f $ruleName) -ForegroundColor Green

$orphans = @(Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue |
        Where-Object { $_.DisplayName -ne $ruleName })
foreach ($orphan in $orphans) {
    if ($PSCmdlet.ShouldProcess($orphan.DisplayName, 'Remove orphan SCP-Allow rule')) {
        $orphan | Remove-NetFirewallRule -ErrorAction Stop
        Write-ScpAllowHost ("  [orphan] removed {0}" -f $orphan.DisplayName) -ForegroundColor Yellow
    }
}

Write-ScpAllowHost 'Done.' -ForegroundColor Cyan
Write-ScpAllowHost ("Run '.\Allow-ScpOutboundFirewall.ps1 -RemoteHost {0} -RemotePort {1} -Verify' to confirm." -f $RemoteHost, $RemotePort) -ForegroundColor DarkGray
