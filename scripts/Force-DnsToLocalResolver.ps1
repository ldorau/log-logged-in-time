<#
.SYNOPSIS
    Forces DNS on Windows 11 Home to a local resolver using the built-in
    Windows Defender Firewall plus the Windows DNS client settings.

.DESCRIPTION
    Windows Firewall cannot DNAT/redirect packets (it cannot rewrite a query
    aimed at 8.8.8.8 into one aimed at your LAN resolver). This script does
    the strongest equivalent available with built-in Home-edition tools:

      1) Sets each eligible network adapter's DNS server list to the target
         LAN resolver IP (-DnsServer) so normal apps use that resolver.
      2) Adds outbound Block rules for TCP/UDP port 53 to every IPv4 address
         *except* that IP, and blocks all outbound IPv6 DNS (TCP/UDP 53),
         so hardcoded public resolvers cannot be reached on classic DNS.

    Managed firewall rules use the "DNS-Force:" display-name prefix.

.PARAMETER DnsServer
    IPv4 address of the LAN DNS resolver. Optional when -ConfigPath provides
    ServerDNS (or when only -Remove is used).

.PARAMETER ConfigPath
    LoginTimeLogger runtime config JSON. When DnsServer is empty, reads
    ServerDNS from this file.

.PARAMETER Remove
    Removes rules created by this script and optionally restores adapter DNS
    to DHCP (see -RestoreDnsToDhcp). Cannot be combined with -Verify.

.PARAMETER RestoreDnsToDhcp
    With -Remove, reset eligible adapters to DNS via DHCP.

.PARAMETER Verify
    Checks rule presence and that adapters point at DnsServer; optionally
    probes TCP/53 reachability to DnsServer vs a public resolver.

.PARAMETER InterfaceAlias
    Limit DNS client changes to specific adapter alias(es). Default: all
    up Ethernet/Wi-Fi interfaces that are not virtual switches.

.PARAMETER Quiet
    With -Verify, suppress detail output and rely on the exit code
    (0 = OK, 1 = FAIL).

.EXAMPLE
    # Elevated PowerShell: point DNS at the LAN resolver and lock port 53:
    .\Force-DnsToLocalResolver.ps1 -DnsServer 10.0.0.1

.EXAMPLE
    .\Force-DnsToLocalResolver.ps1 -ConfigPath "$env:USERPROFILE\LoginTimeLogger\config.json" -Verify

.EXAMPLE
    .\Force-DnsToLocalResolver.ps1 -Remove -RestoreDnsToDhcp

.NOTES
    - Add/remove requires Administrator.
    - Does not forward/NAT foreign DNS destinations; it blocks them.
    - Encrypted DNS (DoH/DoT on 443/853) is out of scope here; use
      Block-DoH-Firewall.ps1 for those endpoints.
    - Prefer setting ServerDNS in the LoginTimeLogger config instead of a
      hardcoded IP in scripts.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [string]$DnsServer = '',
    [string]$ConfigPath = '',

    [switch]$Remove,
    [switch]$RestoreDnsToDhcp,
    [switch]$Verify,
    [string[]]$InterfaceAlias,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'DNS-Force:'

if ($Remove -and $Verify) {
    throw 'Specify only one of -Remove or -Verify (not both).'
}

if ([string]::IsNullOrWhiteSpace($DnsServer) -and -not [string]::IsNullOrWhiteSpace($ConfigPath) -and (Test-Path -LiteralPath $ConfigPath)) {
    try {
        $cfgRaw = Get-Content -LiteralPath $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        $cfgServerDns = $null
        $dnsProp = $cfgRaw.PSObject.Properties['ServerDNS']
        if ($null -ne $dnsProp) {
            $cfgServerDns = $dnsProp.Value
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$cfgServerDns)) {
            $DnsServer = [string]$cfgServerDns.Trim()
        }
    }
    catch {
        throw ("Could not read ServerDNS from config '{0}': {1}" -f $ConfigPath, $_.Exception.Message)
    }
}

if (-not $Remove) {
    if ([string]::IsNullOrWhiteSpace($DnsServer)) {
        throw 'DnsServer is required (pass -DnsServer or set ServerDNS in -ConfigPath).'
    }
    try {
        $parsedDns = [System.Net.IPAddress]::Parse($DnsServer)
        if ($parsedDns.AddressFamily -ne [System.Net.Sockets.AddressFamily]::InterNetwork) {
            throw 'not IPv4'
        }
    }
    catch {
        throw ("DnsServer must be an IPv4 address (got '{0}')." -f $DnsServer)
    }
}

function Write-DnsForceHost {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray
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
Import-Module DnsClient -ErrorAction SilentlyContinue
Import-Module NetAdapter -ErrorAction SilentlyContinue
Import-Module NetTCPIP -ErrorAction SilentlyContinue

function Get-ManagedDnsForceRules {
    Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue
}

function Get-DnsForceIPv4BlockRanges {
    param([Parameter(Mandatory)][string]$AllowIpv4)

    $octets = @($AllowIpv4.Split('.') | ForEach-Object { [int]$_ })
    if ($octets.Count -ne 4) {
        throw "Invalid IPv4 address: $AllowIpv4"
    }

    # Two contiguous ranges covering all IPv4 except $AllowIpv4.
    $prev = [int[]]@($octets[0], $octets[1], $octets[2], $octets[3])
    $next = [int[]]@($octets[0], $octets[1], $octets[2], $octets[3])

    # previous address
    $i = 3
    while ($i -ge 0) {
        if ($prev[$i] -gt 0) {
            $prev[$i]--
            break
        }
        $prev[$i] = 255
        $i--
    }
    if ($i -lt 0) {
        $lowRange = $null  # Allow IP is 0.0.0.0 - only high range
    }
    else {
        # Avoid 0.0.0.0 as a lone endpoint; some Windows builds reject it as a prefix.
        $lowRange = '0.0.0.0-{0}.{1}.{2}.{3}' -f $prev[0], $prev[1], $prev[2], $prev[3]
        if ($lowRange -eq '0.0.0.0-0.0.0.0') {
            $lowRange = '0.0.0.0/32'
        }
    }

    # next address
    $i = 3
    while ($i -ge 0) {
        if ($next[$i] -lt 255) {
            $next[$i]++
            break
        }
        $next[$i] = 0
        $i--
    }
    if ($i -lt 0) {
        $highRange = $null  # Allow IP is 255.255.255.255
    }
    else {
        # 255.255.255.255 as range end is invalid on many Windows Firewall builds.
        $highRange = '{0}.{1}.{2}.{3}-255.255.255.254' -f $next[0], $next[1], $next[2], $next[3]
    }

    $ranges = New-Object System.Collections.Generic.List[string]
    if ($lowRange) { $ranges.Add($lowRange) }
    if ($highRange) { $ranges.Add($highRange) }
    return @($ranges)
}

function Get-EligibleDnsAdapters {
    param([string[]]$AliasFilter)

    $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
            $_.Status -eq 'Up' -and
            $_.HardwareInterface -eq $true -and
            ($_.MediaType -match '802\.3|Native 802\.11|Wireless|Ethernet' -or $_.InterfaceDescription -match 'Ethernet|Wi-?Fi|Wireless|WLAN')
        })

    # Fallback: any Up non-loopback IP-enabled interface if hardware filter is empty.
    if ($adapters.Count -eq 0) {
        $adapters = @(Get-NetAdapter -ErrorAction Stop | Where-Object {
                $_.Status -eq 'Up' -and $_.Name -notmatch 'Loopback'
            })
    }

    if ($AliasFilter -and $AliasFilter.Count -gt 0) {
        $adapters = @($adapters | Where-Object { $AliasFilter -contains $_.Name })
    }

    return $adapters
}

function Set-AdapterDnsToResolver {
    param(
        [Parameter(Mandatory)][string]$Server,
        [string[]]$AliasFilter
    )

    $adapters = Get-EligibleDnsAdapters -AliasFilter $AliasFilter
    if ($adapters.Count -eq 0) {
        Write-Warning 'No eligible network adapters found to set DNS.'
        return @()
    }

    $changed = New-Object System.Collections.Generic.List[string]
    foreach ($adapter in $adapters) {
        $alias = $adapter.Name
        if ($PSCmdlet.ShouldProcess($alias, "Set DNS servers to $Server")) {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ServerAddresses @($Server) -ErrorAction Stop
            Write-Host ("  [dns]  {0} -> {1}" -f $alias, $Server) -ForegroundColor Green
            $changed.Add($alias)
        }
    }
    return @($changed)
}

function Reset-AdapterDnsToDhcp {
    param([string[]]$AliasFilter)

    $adapters = Get-EligibleDnsAdapters -AliasFilter $AliasFilter
    foreach ($adapter in $adapters) {
        $alias = $adapter.Name
        if ($PSCmdlet.ShouldProcess($alias, 'Reset DNS servers to DHCP')) {
            Set-DnsClientServerAddress -InterfaceAlias $alias -ResetServerAddresses -ErrorAction Stop
            Write-Host ("  [dns]  {0} -> DHCP" -f $alias) -ForegroundColor Yellow
        }
    }
}

function New-DnsForceFirewallRules {
    param([Parameter(Mandatory)][string]$Server)

    $v4Ranges = Get-DnsForceIPv4BlockRanges -AllowIpv4 $Server
    if ($v4Ranges.Count -eq 0) {
        throw "Could not build IPv4 exclude ranges for $Server"
    }

    # ::/0 is rejected by New-NetFirewallRule on many builds ("address prefix invalid").
    # Block common IPv6 DNS-capable space instead (global unicast + ULA).
    $ipv6Block = @('2000::/3', 'fc00::/7')

    $specs = @(
        @{ Name = "$RulePrefix Block IPv4 UDP/53 except $Server"; Protocol = 'UDP'; RemoteAddress = $v4Ranges }
        @{ Name = "$RulePrefix Block IPv4 TCP/53 except $Server"; Protocol = 'TCP'; RemoteAddress = $v4Ranges }
        @{ Name = "$RulePrefix Block IPv6 UDP/53"; Protocol = 'UDP'; RemoteAddress = $ipv6Block }
        @{ Name = "$RulePrefix Block IPv6 TCP/53"; Protocol = 'TCP'; RemoteAddress = $ipv6Block }
    )

    $ruleErrors = New-Object System.Collections.Generic.List[string]
    foreach ($spec in $specs) {
        $existing = Get-NetFirewallRule -DisplayName $spec.Name -ErrorAction SilentlyContinue
        if ($existing) {
            if ($PSCmdlet.ShouldProcess($spec.Name, 'Recreate firewall rule')) {
                $existing | Remove-NetFirewallRule -ErrorAction Stop
            }
            else {
                continue
            }
        }
        elseif (-not $PSCmdlet.ShouldProcess($spec.Name, 'Create outbound block firewall rule')) {
            continue
        }

        try {
            New-NetFirewallRule `
                -DisplayName $spec.Name `
                -Description ("Blocks outbound DNS $($spec.Protocol)/53 except LAN resolver $Server (managed by Force-DnsToLocalResolver.ps1)") `
                -Direction Outbound `
                -Action Block `
                -Protocol $spec.Protocol `
                -RemotePort 53 `
                -RemoteAddress $spec.RemoteAddress `
                -Profile Any `
                -Enabled True `
                -ErrorAction Stop `
                | Out-Null

            Write-Host ("  [fw]   {0}" -f $spec.Name) -ForegroundColor Green
        }
        catch {
            $ruleErrors.Add(('{0}: {1}' -f $spec.Name, $_.Exception.Message))
            Write-Host ("  [fw]   FAILED {0} - {1}" -f $spec.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }

    # Explicit allow to the LAN resolver (documentation / clarity). Block-except
    # ranges already permit this IP; Allow does not override a conflicting Block.
    $allowSpecs = @(
        @{ Name = "$RulePrefix Allow UDP/53 to $Server"; Protocol = 'UDP' }
        @{ Name = "$RulePrefix Allow TCP/53 to $Server"; Protocol = 'TCP' }
    )
    foreach ($spec in $allowSpecs) {
        $existing = Get-NetFirewallRule -DisplayName $spec.Name -ErrorAction SilentlyContinue
        if ($existing) {
            if ($PSCmdlet.ShouldProcess($spec.Name, 'Recreate allow firewall rule')) {
                $existing | Remove-NetFirewallRule -ErrorAction Stop
            }
            else {
                continue
            }
        }
        elseif (-not $PSCmdlet.ShouldProcess($spec.Name, 'Create outbound allow firewall rule')) {
            continue
        }

        try {
            New-NetFirewallRule `
                -DisplayName $spec.Name `
                -Description ("Allows outbound DNS $($spec.Protocol)/53 to LAN resolver $Server (managed by Force-DnsToLocalResolver.ps1)") `
                -Direction Outbound `
                -Action Allow `
                -Protocol $spec.Protocol `
                -RemotePort 53 `
                -RemoteAddress $Server `
                -Profile Any `
                -Enabled True `
                -ErrorAction Stop `
                | Out-Null

            Write-Host ("  [fw]   {0}" -f $spec.Name) -ForegroundColor Green
        }
        catch {
            $ruleErrors.Add(('{0}: {1}' -f $spec.Name, $_.Exception.Message))
            Write-Host ("  [fw]   FAILED {0} - {1}" -f $spec.Name, $_.Exception.Message) -ForegroundColor Red
        }
    }

    if ($ruleErrors.Count -gt 0) {
        throw ("Failed to create {0} DNS-Force firewall rule(s):`r`n - {1}" -f `
                $ruleErrors.Count, ($ruleErrors -join "`r`n - "))
    }
}

# =============================================================================
# -Remove
# =============================================================================
if ($Remove) {
    Write-Host "Removing DNS-Force firewall rules (prefix '$RulePrefix')..." -ForegroundColor Yellow
    $existing = @(Get-ManagedDnsForceRules)
    if ($existing.Count -eq 0) {
        Write-Host 'No matching firewall rules found.' -ForegroundColor Green
    }
    elseif ($PSCmdlet.ShouldProcess("$($existing.Count) DNS-Force rule(s)", 'Remove firewall rules')) {
        $existing | Remove-NetFirewallRule
        Write-Host "Removed $($existing.Count) rule(s)." -ForegroundColor Green
    }

    if ($RestoreDnsToDhcp) {
        Write-Host 'Restoring adapter DNS to DHCP...' -ForegroundColor Yellow
        Reset-AdapterDnsToDhcp -AliasFilter $InterfaceAlias
    }
    else {
        Write-Host 'Adapter DNS left unchanged (pass -RestoreDnsToDhcp to reset to DHCP).' -ForegroundColor DarkGray
    }
    exit 0
}

# =============================================================================
# -Verify
# =============================================================================
if ($Verify) {
    Write-DnsForceHost '=== DNS-Force verification ===' -ForegroundColor Cyan
    Write-DnsForceHost ("Expected resolver: {0}" -f $DnsServer)
    Write-DnsForceHost ''

    $rules = @(Get-ManagedDnsForceRules)
    Write-DnsForceHost ("Managed firewall rules: {0}" -f $rules.Count)
    if (-not $Quiet) {
        $rules | Sort-Object DisplayName | ForEach-Object {
            $color = if ($_.Enabled -eq 'True' -and $_.Action -in @('Block', 'Allow')) { 'Green' } else { 'Yellow' }
            Write-Host ("  [{0}] {1} Action={2} Enabled={3}" -f $_.Direction, $_.DisplayName, $_.Action, $_.Enabled) -ForegroundColor $color
        }
    }
    if ($rules.Count -lt 4) {
        Write-DnsForceHost 'WARNING: Expected at least 4 DNS-Force rules (IPv4 UDP/TCP block + IPv6 UDP/TCP block).' -ForegroundColor Yellow
    }

    Write-DnsForceHost ''
    Write-DnsForceHost 'Adapter DNS servers:' -ForegroundColor Cyan
    $adapters = Get-EligibleDnsAdapters -AliasFilter $InterfaceAlias
    $dnsOk = $true
    if ($adapters.Count -eq 0) {
        Write-DnsForceHost '  (no eligible adapters)' -ForegroundColor Yellow
        $dnsOk = $false
    }
    foreach ($adapter in $adapters) {
        $dns = Get-DnsClientServerAddress -InterfaceAlias $adapter.Name -AddressFamily IPv4 -ErrorAction SilentlyContinue
        $servers = @($dns.ServerAddresses)
        $match = ($servers.Count -ge 1 -and $servers[0] -eq $DnsServer)
        if (-not $match) { $dnsOk = $false }
        $flag = if ($match) { 'OK' } else { 'MISMATCH' }
        Write-DnsForceHost ("  [{0}] {1}: {2}" -f $flag, $adapter.Name, ($(if ($servers) { $servers -join ', ' } else { '(none)' }))) `
            -ForegroundColor $(if ($match) { 'Green' } else { 'Red' })
    }

    Write-DnsForceHost ''
    Write-DnsForceHost 'Live TCP/53 probes (firewall path):' -ForegroundColor Cyan
    $probeOk = $true
    try {
        $toLocal = Test-NetConnection -ComputerName $DnsServer -Port 53 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($toLocal.TcpTestSucceeded) {
            Write-DnsForceHost ("  {0}:53 REACHABLE (ok)" -f $DnsServer) -ForegroundColor Green
        }
        else {
            Write-DnsForceHost ("  {0}:53 NOT reachable (resolver down or UDP-only)" -f $DnsServer) -ForegroundColor Yellow
        }
    }
    catch {
        Write-DnsForceHost ("  {0}:53 probe error: {1}" -f $DnsServer, $_.Exception.Message) -ForegroundColor Yellow
    }

    try {
        $toPublic = Test-NetConnection -ComputerName '1.1.1.1' -Port 53 -WarningAction SilentlyContinue -ErrorAction Stop
        if ($toPublic.TcpTestSucceeded) {
            Write-DnsForceHost '  1.1.1.1:53 REACHABLE (FAIL - public DNS should be blocked)' -ForegroundColor Red
            $probeOk = $false
        }
        else {
            Write-DnsForceHost '  1.1.1.1:53 blocked/unreachable (ok)' -ForegroundColor Green
        }
    }
    catch {
        Write-DnsForceHost '  1.1.1.1:53 probe failed/blocked (treated as ok)' -ForegroundColor Green
    }

    Write-DnsForceHost ''
    if ($rules.Count -ge 4 -and $dnsOk -and $probeOk) {
        Write-DnsForceHost 'RESULT: DNS forcing looks configured.' -ForegroundColor Green
        exit 0
    }
    Write-DnsForceHost 'RESULT: DNS forcing incomplete or public DNS still reachable.' -ForegroundColor Red
    exit 1
}

# =============================================================================
# Default: configure DNS client + firewall
# =============================================================================
Write-Host ("Forcing DNS to local resolver {0} (Windows Firewall + DNS client)..." -f $DnsServer) -ForegroundColor Cyan
Write-Host 'Note: Firewall blocks other DNS destinations; it does not rewrite/forward foreign destinations.' -ForegroundColor DarkGray
Write-Host ''

Write-Host 'Setting adapter DNS...' -ForegroundColor Cyan
$null = Set-AdapterDnsToResolver -Server $DnsServer -AliasFilter $InterfaceAlias

Write-Host ''
Write-Host 'Installing outbound DNS firewall rules...' -ForegroundColor Cyan
New-DnsForceFirewallRules -Server $DnsServer

Write-Host ''
Write-Host 'Done.' -ForegroundColor Cyan
Write-Host ("Run '.\$(Split-Path -Leaf $PSCommandPath) -Verify' to check, or -Remove -RestoreDnsToDhcp to undo.") -ForegroundColor Cyan
Write-Host 'Tip: also run Block-DoH-Firewall.ps1 so browsers cannot bypass via DoH on 443/853.' -ForegroundColor DarkGray
