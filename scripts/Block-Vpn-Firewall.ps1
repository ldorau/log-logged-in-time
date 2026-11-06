<#
.SYNOPSIS
    Adds, removes, or verifies Windows Defender Firewall outbound rules that
    block known commercial VPN endpoints (and classic VPN ports to those IPs).

.DESCRIPTION
    Creates one firewall rule per provider/protocol/port combination so each
    can be inspected, disabled, or removed individually in wf.msc. All rules
    created by this script share the "VPN-Block:" name prefix, which makes
    them easy to find and clean up later (see -Remove).

    On add/update, existing managed rules are reconciled: remote addresses and
    ports are compared and rules are recreated when they drift. Orphan managed
    rules (prefix match, but no longer expected) are removed.

    Provider IPs are loaded from Block-Vpn-Providers.json beside this script
    when present; otherwise an embedded default table is used.

    Use -Verify to check whether the blocking is actually working: it confirms
    rule configuration (including address/port filters), then performs live
    outbound TCP connection attempts. IPv6 tests are skipped as inconclusive
    when the host has no usable IPv6 default route.

.PARAMETER Remove
    Removes every firewall rule previously created by this script (matched
    by the "VPN-Block:" name prefix) instead of adding them.
    Cannot be combined with -Verify.

.PARAMETER Verify
    Checks the current state instead of adding/removing rules:
      1) Confirms each expected rule exists, is Enabled, Action=Block,
         Direction=Outbound, and remote address/port filters match.
      2) Attempts live TCP connections to every provider IP on classic TCP
         VPN ports (and 443 when -IncludeHttps).
    Cannot be combined with -Remove.

.PARAMETER IncludeHttps
    Also blocks (or, with -Verify, also tests) TCP/UDP port 443 to the same
    provider IPs (VPN-over-HTTPS / stealth endpoints). Enabled by default;
    use -IncludeHttps:$false to skip it.

.PARAMETER ProvidersPath
    Optional path to a JSON object of provider name -> IP array. Default:
    Block-Vpn-Providers.json next to this script.

.PARAMETER Quiet
    With -Verify, suppress tables/details and only rely on the exit code:
      0 = VPN looks blocked (rules OK, no reachable endpoints, >=1 blocked)
      1 = not blocked or rules missing/misconfigured
      2 = inconclusive (no leaks, but no conclusive blocked samples)

.EXAMPLE
    # Run from an elevated PowerShell prompt to add/reconcile the rules:
    .\Block-Vpn-Firewall.ps1

.EXAMPLE
    # Preview what would be created/updated without changing the firewall:
    .\Block-Vpn-Firewall.ps1 -WhatIf

.EXAMPLE
    # Confirm the rules are in place AND actually blocking traffic:
    .\Block-Vpn-Firewall.ps1 -Verify

.EXAMPLE
    # Remove all rules created by this script:
    .\Block-Vpn-Firewall.ps1 -Remove

.NOTES
    - Add/reconcile and -Remove must be run as Administrator.
    - -Verify can run without elevation (reads rules + live TCP tests).
    - Blocks traffic *to listed provider IPs* on classic VPN ports (and 443
      when enabled). It cannot block arbitrary self-hosted VPNs or VPNs that
      use changing/CDN IPs not in the list (Windows Firewall has no SNI filter).
    - Provider IP lists change often; review/update Block-Vpn-Providers.json.
    - UDP rules are configuration-checked only; live UDP verify is unreliable.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Remove,
    [switch]$Verify,
    [bool]$IncludeHttps = $true,
    [string]$ProvidersPath,
    [switch]$Quiet
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'VPN-Block:'

if ($Remove -and $Verify) {
    throw "Specify only one of -Remove or -Verify (not both)."
}

function Write-VpnHost {
    param(
        # Blank lines are intentional in -Verify output; Mandatory alone
        # rejects '' (ParameterArgumentValidationErrorEmptyStringNotAllowed).
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Message,
        [ConsoleColor]$ForegroundColor = [ConsoleColor]::Gray,
        [switch]$Force
    )
    if ($Quiet -and -not $Force) {
        return
    }
    if ($PSBoundParameters.ContainsKey('ForegroundColor')) {
        Write-Host $Message -ForegroundColor $ForegroundColor
    }
    else {
        Write-Host $Message
    }
}

# --- Require elevation for rule changes (Verify is read-only) --------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
$isAdmin = $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $Verify -and -not $isAdmin) {
    Write-Error "This script must be run from an elevated (Administrator) PowerShell prompt (except -Verify)."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name NetSecurity)) {
    throw "NetSecurity module is required (Get/New/Remove-NetFirewallRule)."
}
Import-Module NetSecurity -ErrorAction Stop

# --- Embedded defaults (used when JSON side file is missing) ---------------
$EmbeddedProviders = [ordered]@{
    'CloudflareWARP' = @(
        '162.159.36.1', '162.159.46.1', '162.159.193.1',
        '2606:4700:100::1', '2606:4700:100::2'
    )
    'Mullvad' = @(
        '193.138.218.78', '185.213.154.68', '185.65.134.120',
        '193.32.127.243', '45.83.220.150'
    )
    'ProtonVPN' = @(
        '185.159.156.10', '185.159.157.10', '185.159.158.10', '37.19.21.10'
    )
    'NordVPN' = @(
        '103.86.96.100', '103.86.99.100', '89.46.223.10'
    )
    'ExpressVPN' = @(
        '199.229.252.10', '190.2.132.10', '149.88.19.10'
    )
    'Surfshark' = @(
        '84.17.46.10', '84.17.47.10', '138.199.43.10'
    )
    'PrivateInternetAccess' = @(
        '209.222.18.222', '209.222.18.218', '154.47.29.10'
    )
    'CyberGhost' = @(
        '91.207.175.10', '91.207.174.10', '185.242.4.10'
    )
    'Windscribe' = @(
        '142.44.213.10', '142.44.241.10', '198.245.50.10'
    )
    'IVPN' = @(
        '198.54.132.10', '198.54.134.10', '46.19.136.10'
    )
}

function ConvertTo-ProviderTable {
    param([Parameter(Mandatory)]$InputObject)

    $table = [ordered]@{}
    foreach ($prop in $InputObject.PSObject.Properties) {
        $ips = @($prop.Value | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        if ($ips.Count -gt 0) {
            $table[$prop.Name] = $ips
        }
    }
    return $table
}

function Get-ProviderTable {
    param([string]$Path)

    $scriptDir = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptDir) -and -not [string]::IsNullOrWhiteSpace($PSCommandPath)) {
        $scriptDir = Split-Path -Parent $PSCommandPath
    }
    if ([string]::IsNullOrWhiteSpace($Path)) {
        if ([string]::IsNullOrWhiteSpace($scriptDir)) {
            throw 'Cannot resolve script directory to locate Block-Vpn-Providers.json; pass -ProvidersPath.'
        }
        $Path = Join-Path $scriptDir 'Block-Vpn-Providers.json'
    }

    if (Test-Path -LiteralPath $Path) {
        Write-Host "Loading provider IPs from: $Path" -ForegroundColor DarkGray
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
        $loaded = ConvertTo-ProviderTable -InputObject $raw
        if ($loaded.Count -eq 0) {
            throw "Provider file '$Path' did not contain any provider IP lists."
        }
        return $loaded
    }

    Write-Host "Provider JSON not found at '$Path'; using embedded defaults." -ForegroundColor DarkGray
    return $EmbeddedProviders
}

function Get-RuleName {
    param($ProviderName, $Spec)
    return "$RulePrefix $ProviderName $($Spec.Label) $($Spec.Protocol)/$($Spec.Port)"
}

function Get-ManagedFirewallRules {
    Get-NetFirewallRule -DisplayName "$RulePrefix*" -ErrorAction SilentlyContinue
}

function Normalize-AddressList {
    param([string[]]$Addresses)
    return @($Addresses | ForEach-Object { $_.Trim().ToLowerInvariant() } | Sort-Object -Unique)
}

function Get-RuleRemoteAddresses {
    param([Parameter(Mandatory)]$Rule)
    $filter = $Rule | Get-NetFirewallAddressFilter -ErrorAction Stop
    return @(
        @($filter.RemoteAddress) |
            ForEach-Object { [string]$_ } |
            Where-Object { $_ -and ($_ -ne 'Any') }
    )
}

function Get-RulePortInfo {
    param([Parameter(Mandatory)]$Rule)
    $filter = $Rule | Get-NetFirewallPortFilter -ErrorAction Stop
    return [pscustomobject]@{
        Protocol   = [string]$filter.Protocol
        RemotePort = @($filter.RemotePort | ForEach-Object { [string]$_ })
    }
}

function Test-RuleMatchesExpected {
    param(
        [Parameter(Mandatory)]$Rule,
        [Parameter(Mandatory)][string[]]$ExpectedAddresses,
        [Parameter(Mandatory)]$Spec
    )

    if ($Rule.Enabled -ne 'True' -or $Rule.Action -ne 'Block' -or $Rule.Direction -ne 'Outbound') {
        return [pscustomobject]@{
            Matches = $false
            Reason  = "Enabled=$($Rule.Enabled) Action=$($Rule.Action) Direction=$($Rule.Direction)"
        }
    }

    try {
        $actualAddresses = Normalize-AddressList -Addresses (Get-RuleRemoteAddresses -Rule $Rule)
        $expectedAddresses = Normalize-AddressList -Addresses $ExpectedAddresses
        if (($actualAddresses -join ',') -ne ($expectedAddresses -join ',')) {
            return [pscustomobject]@{
                Matches = $false
                Reason  = 'RemoteAddress mismatch'
            }
        }

        $portInfo = Get-RulePortInfo -Rule $Rule
        $protoOk = [string]::Equals($portInfo.Protocol, $Spec.Protocol, [StringComparison]::OrdinalIgnoreCase)
        $portOk = $portInfo.RemotePort -contains [string]$Spec.Port
        if (-not $protoOk -or -not $portOk) {
            return [pscustomobject]@{
                Matches = $false
                Reason  = "Port/Protocol mismatch (got $($portInfo.Protocol)/$($portInfo.RemotePort -join ','))"
            }
        }
    }
    catch {
        return [pscustomobject]@{
            Matches = $false
            Reason  = "Filter query failed: $($_.Exception.Message)"
        }
    }

    return [pscustomobject]@{ Matches = $true; Reason = 'OK' }
}

function New-VpnBlockRule {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string[]]$Addresses
    )

    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Description "Blocks outbound $($Spec.Label) traffic to $ProviderName VPN endpoints (managed by Block-Vpn-Firewall.ps1)" `
        -Direction Outbound `
        -Action Block `
        -Protocol $Spec.Protocol `
        -RemotePort $Spec.Port `
        -RemoteAddress $Addresses `
        -Program Any `
        -Enabled True `
        -Profile Any `
        | Out-Null
}

function Set-VpnBlockRuleReconciled {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string[]]$Addresses
    )

    $existing = Get-NetFirewallRule -DisplayName $RuleName -ErrorAction SilentlyContinue
    if ($existing) {
        $match = Test-RuleMatchesExpected -Rule $existing -ExpectedAddresses $Addresses -Spec $Spec
        if ($match.Matches) {
            Write-Host "  [ok]     $RuleName" -ForegroundColor DarkGray
            return 'unchanged'
        }

        if ($PSCmdlet.ShouldProcess($RuleName, "Recreate firewall rule (was: $($match.Reason))")) {
            $existing | Remove-NetFirewallRule
            New-VpnBlockRule -RuleName $RuleName -ProviderName $ProviderName -Spec $Spec -Addresses $Addresses
            Write-Host "  [update] $RuleName  ($($match.Reason)) -> $($Addresses -join ', ')" -ForegroundColor Yellow
            return 'updated'
        }
        return 'whatif-update'
    }

    if ($PSCmdlet.ShouldProcess($RuleName, 'Create outbound block firewall rule')) {
        New-VpnBlockRule -RuleName $RuleName -ProviderName $ProviderName -Spec $Spec -Addresses $Addresses
        Write-Host "  [added]  $RuleName  -> $($Addresses -join ', ')" -ForegroundColor Green
        return 'added'
    }
    return 'whatif-add'
}

function Test-IPv6OutboundAvailable {
    $defaultRoute = Get-NetRoute -AddressFamily IPv6 -DestinationPrefix '::/0' -ErrorAction SilentlyContinue |
        Where-Object { $_.NextHop -and $_.NextHop -ne '::' }
    if (-not $defaultRoute) {
        return $false
    }

    $globalAddress = Get-NetIPAddress -AddressFamily IPv6 -ErrorAction SilentlyContinue |
        Where-Object {
            $_.AddressState -eq 'Preferred' -and
            $_.IPAddress -notlike 'fe80*' -and
            $_.IPAddress -ne '::1' -and
            $_.PrefixOrigin -ne 'WellKnown'
        }
    return [bool]$globalAddress
}

$Providers = Get-ProviderTable -Path $ProvidersPath

# --- Build the list of (Protocol, Port, Label) combinations we manage ------
$PortSpecs = @(
    @{ Protocol = 'UDP'; Port = 1194; Label = 'OpenVPN' }
    @{ Protocol = 'TCP'; Port = 1194; Label = 'OpenVPNT' }
    @{ Protocol = 'UDP'; Port = 51820; Label = 'WireGuard' }
    @{ Protocol = 'UDP'; Port = 500; Label = 'IKE' }
    @{ Protocol = 'UDP'; Port = 4500; Label = 'IPSecNATT' }
    @{ Protocol = 'TCP'; Port = 1723; Label = 'PPTP' }
)
if ($IncludeHttps) {
    $PortSpecs += @{ Protocol = 'TCP'; Port = 443; Label = 'HTTPS' }
    $PortSpecs += @{ Protocol = 'UDP'; Port = 443; Label = 'QUIC' }
}

$expectedRuleNames = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($providerName in $Providers.Keys) {
    foreach ($spec in $PortSpecs) {
        $null = $expectedRuleNames.Add((Get-RuleName -ProviderName $providerName -Spec $spec))
    }
}

# =============================================================================
# -Remove : delete every rule this script created
# =============================================================================
if ($Remove) {
    Write-Host "Removing all firewall rules created by this script (prefix '$RulePrefix')..." -ForegroundColor Yellow
    $existing = @(Get-ManagedFirewallRules)
    if ($existing.Count -eq 0) {
        Write-Host 'No matching rules found.' -ForegroundColor Green
        exit 0
    }

    if ($PSCmdlet.ShouldProcess("$($existing.Count) rule(s) with prefix '$RulePrefix'", 'Remove firewall rules')) {
        $existing | Remove-NetFirewallRule
        Write-Host "Removed $($existing.Count) rule(s)." -ForegroundColor Green
    }
    exit 0
}

# =============================================================================
# -Verify : check rule configuration + live connectivity
# =============================================================================
if ($Verify) {
    Write-VpnHost '=== Step 1/2: Checking firewall rule configuration ===' -ForegroundColor Cyan
    Write-VpnHost ''

    $ruleResults = @()
    foreach ($providerName in $Providers.Keys) {
        $ips = @($Providers[$providerName])
        foreach ($spec in $PortSpecs) {
            $ruleName = Get-RuleName -ProviderName $providerName -Spec $spec
            $rule = Get-NetFirewallRule -DisplayName $ruleName -ErrorAction SilentlyContinue

            $state = 'MISSING'
            if ($rule) {
                $match = Test-RuleMatchesExpected -Rule $rule -ExpectedAddresses $ips -Spec $spec
                $state = if ($match.Matches) { 'OK' } else { "MISMATCH: $($match.Reason)" }
            }

            $ruleResults += [PSCustomObject]@{
                Provider = $providerName
                Label    = $spec.Label
                Proto    = $spec.Protocol
                Port     = $spec.Port
                RuleName = $ruleName
                State    = $state
            }
        }
    }
    if (-not $Quiet) {
        $ruleResults | Format-Table Provider, Label, Proto, Port, State -AutoSize
    }

    $orphans = @(Get-ManagedFirewallRules | Where-Object { -not $expectedRuleNames.Contains($_.DisplayName) })
    if ($orphans.Count -gt 0) {
        Write-VpnHost "WARNING: $($orphans.Count) orphan managed rule(s) present (not in current provider/port set):" -ForegroundColor Yellow
        $orphans | ForEach-Object { Write-VpnHost "  - $($_.DisplayName)" -ForegroundColor Yellow }
    }

    $missing = @($ruleResults | Where-Object { $_.State -ne 'OK' })
    if ($missing.Count -gt 0) {
        Write-VpnHost "WARNING: $($missing.Count) rule(s) are missing or misconfigured. Run the script without -Verify/-Remove to (re)create them." -ForegroundColor Red
    }
    else {
        Write-VpnHost "All $($ruleResults.Count) expected rules exist with matching filters." -ForegroundColor Green
    }

    Write-VpnHost ''
    Write-VpnHost '=== Step 2/2: Live connectivity test (TCP only) ===' -ForegroundColor Cyan
    Write-VpnHost "Attempting real outbound TCP connections. 'BLOCKED' = good; 'SKIP' = inconclusive." -ForegroundColor Cyan
    Write-VpnHost ''

    $ipv6Available = Test-IPv6OutboundAvailable
    if (-not $ipv6Available) {
        Write-VpnHost 'Host has no usable IPv6 default route/global address; IPv6 endpoints will be SKIP (inconclusive).' -ForegroundColor Yellow
        Write-VpnHost ''
    }

    $tcpSpecs = @($PortSpecs | Where-Object { $_.Protocol -eq 'TCP' })
    $connResults = @()

    foreach ($providerName in $Providers.Keys) {
        foreach ($ip in @($Providers[$providerName])) {
            $isIPv6 = $ip -like '*:*'
            foreach ($spec in $tcpSpecs) {
                $status = $null
                $note = ''

                if ($isIPv6 -and -not $ipv6Available) {
                    $status = 'SKIP (no IPv6)'
                    $note = 'Inconclusive: host has no usable IPv6 outbound path'
                }
                else {
                    try {
                        $test = Test-NetConnection -ComputerName $ip -Port $spec.Port `
                            -WarningAction SilentlyContinue -ErrorAction Stop
                        if ([bool]$test.TcpTestSucceeded) {
                            $status = 'NOT BLOCKED !!'
                        }
                        else {
                            $status = 'BLOCKED (ok)'
                        }
                    }
                    catch {
                        if ($isIPv6) {
                            $status = 'SKIP (IPv6 error)'
                            $note = "Inconclusive: $($_.Exception.Message)"
                        }
                        else {
                            # IPv4 hard failures (no route etc.) are inconclusive, not proof of block.
                            $status = 'SKIP (IPv4 error)'
                            $note = "Inconclusive: $($_.Exception.Message)"
                        }
                    }
                }

                $connResults += [PSCustomObject]@{
                    Provider = $providerName
                    IP       = $ip
                    Proto    = $spec.Protocol
                    Port     = $spec.Port
                    Purpose  = $spec.Label
                    Status   = $status
                    Note     = $note
                }
            }
        }
    }

    if (-not $Quiet) {
        $connResults | Format-Table Provider, IP, Proto, Port, Purpose, Status, Note -AutoSize
    }

    $leaky = @($connResults | Where-Object { $_.Status -eq 'NOT BLOCKED !!' })
    $skipped = @($connResults | Where-Object { $_.Status -like 'SKIP*' })
    $blocked = @($connResults | Where-Object { $_.Status -eq 'BLOCKED (ok)' })

    Write-VpnHost ''
    $verifyExit = 0
    if ($missing.Count -gt 0 -or $leaky.Count -gt 0) {
        $verifyExit = 1
        if ($leaky.Count -gt 0) {
            Write-VpnHost "RESULT: $($leaky.Count) endpoint(s) are still REACHABLE. VPN is NOT fully blocked:" -ForegroundColor Red
            $leaky | ForEach-Object { Write-VpnHost "  - $($_.Provider) $($_.IP):$($_.Port)/$($_.Proto)" -ForegroundColor Red }
            Write-VpnHost 'Check that the rules exist/enabled (Step 1), that no VPN/split-tunnel bypasses the firewall, and that the correct Network Profile (Domain/Private/Public) is active.' -ForegroundColor Yellow
        }
        if ($missing.Count -gt 0) {
            Write-VpnHost "RESULT: $($missing.Count) expected firewall rule(s) missing or mismatched." -ForegroundColor Red
        }
    }
    elseif ($blocked.Count -eq 0) {
        $verifyExit = 2
        Write-VpnHost "RESULT: No conclusive BLOCKED samples ($($skipped.Count) skipped). Cannot confirm blocking from live tests alone." -ForegroundColor Yellow
    }
    else {
        $msg = "RESULT: $($blocked.Count) tested TCP endpoint(s) are blocked."
        if ($skipped.Count -gt 0) {
            $msg += (' ({0} skipped/inconclusive - not counted as pass.)' -f $skipped.Count)
            Write-VpnHost $msg -ForegroundColor Yellow
        }
        else {
            Write-VpnHost ($msg + ' VPN blocking looks good for tested endpoints.') -ForegroundColor Green
        }
        $verifyExit = 0
    }

    $udpSpecs = @($PortSpecs | Where-Object { $_.Protocol -eq 'UDP' })
    if ($udpSpecs.Count -gt 0) {
        $udpLabels = @($udpSpecs | ForEach-Object { $_.Label }) -join ', '
        $udpPorts = @($udpSpecs | ForEach-Object { $_.Port } | Select-Object -Unique) -join ', '
        Write-VpnHost ''
        Write-VpnHost ('NOTE: UDP rules ({0} on port(s) {1}) were checked for configuration only (Step 1).' -f $udpLabels, $udpPorts) -ForegroundColor Yellow
        Write-VpnHost '      Live UDP blocking cannot be reliably verified from PowerShell (no connection handshake to test against).' -ForegroundColor Yellow
    }

    Write-VpnHost ''
    Write-VpnHost 'Companion controls reminder: firewall IP lists cannot stop every stealth VPN; keep Block-Vpn-Providers.json updated.' -ForegroundColor DarkGray
    exit $verifyExit
}

# =============================================================================
# Default action : add / reconcile the rules
# =============================================================================
Write-Host 'Adding/reconciling outbound block rules for known VPN endpoints...' -ForegroundColor Cyan

$counts = @{
    added     = 0
    updated   = 0
    unchanged = 0
}

foreach ($providerName in $Providers.Keys) {
    $ips = @($Providers[$providerName])
    foreach ($spec in $PortSpecs) {
        $ruleName = Get-RuleName -ProviderName $providerName -Spec $spec
        $result = Set-VpnBlockRuleReconciled -RuleName $ruleName -ProviderName $providerName -Spec $spec -Addresses $ips
        switch ($result) {
            'added' { $counts.added++ }
            'updated' { $counts.updated++ }
            'unchanged' { $counts.unchanged++ }
        }
    }
}

# Remove orphan managed rules left from older provider/port sets
$orphans = @(Get-ManagedFirewallRules | Where-Object { -not $expectedRuleNames.Contains($_.DisplayName) })
$removedOrphans = 0
foreach ($orphan in $orphans) {
    if ($PSCmdlet.ShouldProcess($orphan.DisplayName, 'Remove orphan managed VPN-Block rule')) {
        $orphan | Remove-NetFirewallRule
        Write-Host "  [orphan] removed $($orphan.DisplayName)" -ForegroundColor Yellow
        $removedOrphans++
    }
}

Write-Host ''
Write-Host ("Done. added={0}; updated={1}; unchanged={2}; orphansRemoved={3}" -f `
        $counts.added, $counts.updated, $counts.unchanged, $removedOrphans) -ForegroundColor Cyan
$leaf = Split-Path -Leaf $PSCommandPath
Write-Host "Run '.\$leaf -Verify' to confirm they are working, or -Remove to delete them all." -ForegroundColor Cyan
Write-Host 'Note: VPN provider IPs change; update Block-Vpn-Providers.json periodically. Stealth/CDN VPNs may still bypass.' -ForegroundColor DarkGray

