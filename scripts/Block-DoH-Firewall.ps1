<#
.SYNOPSIS
    Adds, removes, or verifies Windows Defender Firewall outbound rules that
    block DNS-over-HTTPS (DoH) and DNS-over-TLS (DoT) to a list of known
    public encrypted-DNS resolver IP addresses.

.DESCRIPTION
    Creates one firewall rule per provider/protocol/port combination so each
    can be inspected, disabled, or removed individually in wf.msc. All rules
    created by this script share the "DoH-Block:" name prefix, which makes
    them easy to find and clean up later (see -Remove).

    On add/update, existing managed rules are reconciled: remote addresses and
    ports are compared and rules are recreated when they drift. Orphan managed
    rules (prefix match, but no longer expected) are removed.

    Provider IPs are loaded from Block-DoH-Providers.json beside this script
    when present; otherwise an embedded default table is used.

    Use -Verify to check whether the blocking is actually working: it confirms
    rule configuration (including address/port filters), then performs live
    outbound TCP connection attempts. IPv6 tests are skipped as inconclusive
    when the host has no usable IPv6 default route.

.PARAMETER Remove
    Removes every firewall rule previously created by this script (matched
    by the "DoH-Block:" name prefix) instead of adding them.
    Cannot be combined with -Verify.

.PARAMETER Verify
    Checks the current state instead of adding/removing rules:
      1) Confirms each expected rule exists, is Enabled, Action=Block,
         Direction=Outbound, and remote address/port filters match.
      2) Attempts live TCP connections to every provider IP on port 443
         (DoH) and, if -IncludeDoT, port 853 (DoT).
    Cannot be combined with -Remove.

.PARAMETER IncludeDoT
    Also blocks (or, with -Verify, also tests) TCP/UDP port 853
    (DNS-over-TLS) on the same IP addresses. Enabled by default; use
    -IncludeDoT:$false to skip it.

.PARAMETER ProvidersPath
    Optional path to a JSON object of provider name -> IP array. Default:
    Block-DoH-Providers.json next to this script.

.EXAMPLE
    # Run from an elevated PowerShell prompt to add/reconcile the rules:
    .\Block-DoH-Firewall.ps1

.EXAMPLE
    # Preview what would be created/updated without changing the firewall:
    .\Block-DoH-Firewall.ps1 -WhatIf

.EXAMPLE
    # Confirm the rules are in place AND actually blocking traffic:
    .\Block-DoH-Firewall.ps1 -Verify

.EXAMPLE
    # Remove all rules created by this script:
    .\Block-DoH-Firewall.ps1 -Remove

.NOTES
    - Must be run as Administrator (Windows Firewall rule changes require it).
    - This blocks HTTPS/TLS *to these specific IPs only*. It does not block
      port 53 plain DNS to the same IPs, and it cannot block arbitrary
      self-hosted DoH servers (Windows Firewall has no domain/SNI filtering).
    - Provider IP lists change occasionally; review/update them periodically
      (edit Block-DoH-Providers.json or the embedded defaults).
    - UDP blocking (DoH3/QUIC on 443, DoT-over-QUIC on 853) cannot be
      reliably verified from PowerShell: Windows normally lets a UDP send()
      call succeed even when the firewall silently drops the packet, so
      there is no reliable application-level signal to test against. -Verify
      only reports the UDP rules' configuration state, not live reachability.
    - Companion controls (firewall alone is not enough for "no DoH anywhere"):
        * Disable browser Secure DNS / DoH (Chrome/Edge/Firefox settings or
          enterprise policy).
        * Windows: Settings > Network > DNS > disable "DNS over HTTPS", or
          set DoH via policy (e.g. Administrative Templates / MDM).
        * Consider NRPT / forced plain DNS to a controlled resolver if you
          need organization-wide DNS path control.
#>

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'Medium')]
param(
    [switch]$Remove,
    [switch]$Verify,
    [bool]$IncludeDoT = $true,
    [string]$ProvidersPath
)

$ErrorActionPreference = 'Stop'
$RulePrefix = 'DoH-Block:'

if ($Remove -and $Verify) {
    throw "Specify only one of -Remove or -Verify (not both)."
}

# --- Require elevation -----------------------------------------------------
$currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($currentIdentity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Error "This script must be run from an elevated (Administrator) PowerShell prompt."
    exit 1
}

if (-not (Get-Module -ListAvailable -Name NetSecurity)) {
    throw "NetSecurity module is required (Get/New/Remove-NetFirewallRule)."
}
Import-Module NetSecurity -ErrorAction Stop

# --- Embedded defaults (used when JSON side file is missing) ---------------
$EmbeddedProviders = [ordered]@{
    'Cloudflare' = @(
        '1.1.1.1', '1.0.0.1', '1.1.1.2', '1.0.0.2', '1.1.1.3', '1.0.0.3',
        '2606:4700:4700::1111', '2606:4700:4700::1001',
        '2606:4700:4700::1112', '2606:4700:4700::1002',
        '2606:4700:4700::1113', '2606:4700:4700::1003'
    )
    'Google' = @(
        '8.8.8.8', '8.8.4.4',
        '2001:4860:4860::8888', '2001:4860:4860::8844'
    )
    'Quad9' = @(
        '9.9.9.9', '9.9.9.10', '9.9.9.11',
        '149.112.112.112', '149.112.112.10', '149.112.112.11',
        '2620:fe::fe', '2620:fe::9', '2620:fe::10', '2620:fe::11',
        '2620:fe::fe:9', '2620:fe::fe:10', '2620:fe::fe:11'
    )
    'OpenDNS' = @(
        '208.67.222.222', '208.67.220.220',
        '208.67.222.123', '208.67.220.123',
        '2620:119:35::35', '2620:119:53::53'
    )
    'AdGuardDNS' = @(
        '94.140.14.14', '94.140.15.15', '94.140.14.15', '94.140.15.16',
        '2a10:50c0::ad1:ff', '2a10:50c0::ad2:ff',
        '2a10:50c0::ad1:ffb', '2a10:50c0::ad2:ffb'
    )
    'NextDNS' = @(
        '45.90.28.0', '45.90.30.0',
        '2a07:a8c0::', '2a07:a8c1::'
    )
    'Mullvad' = @(
        '194.242.2.2', '194.242.2.3', '194.242.2.4',
        '194.242.2.5', '194.242.2.6', '194.242.2.9',
        '2a07:e340::2', '2a07:e340::3', '2a07:e340::4',
        '2a07:e340::5', '2a07:e340::6', '2a07:e340::9'
    )
    'ControlD' = @(
        '76.76.2.0', '76.76.10.0',
        '2606:1a40::', '2606:1a40:1::'
    )
    'CleanBrowsing' = @(
        '185.228.168.9', '185.228.169.9',
        '185.228.168.10', '185.228.169.11',
        '2a0d:2a00:1::2', '2a0d:2a00:2::2',
        '2a0d:2a00:1::1', '2a0d:2a00:2::1'
    )
    'DnsSb' = @(
        '185.222.222.222', '185.184.222.222',
        '2a09::', '2a09::1'
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
            throw 'Cannot resolve script directory to locate Block-DoH-Providers.json; pass -ProvidersPath.'
        }
        $Path = Join-Path $scriptDir 'Block-DoH-Providers.json'
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

function New-DoHBlockRule {
    param(
        [Parameter(Mandatory)][string]$RuleName,
        [Parameter(Mandatory)][string]$ProviderName,
        [Parameter(Mandatory)]$Spec,
        [Parameter(Mandatory)][string[]]$Addresses
    )

    New-NetFirewallRule `
        -DisplayName $RuleName `
        -Description "Blocks outbound $($Spec.Label) traffic to $ProviderName resolvers (managed by Block-DoH-Firewall.ps1)" `
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

function Set-DoHBlockRuleReconciled {
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
            New-DoHBlockRule -RuleName $RuleName -ProviderName $ProviderName -Spec $Spec -Addresses $Addresses
            Write-Host "  [update] $RuleName  ($($match.Reason)) -> $($Addresses -join ', ')" -ForegroundColor Yellow
            return 'updated'
        }
        return 'whatif-update'
    }

    if ($PSCmdlet.ShouldProcess($RuleName, 'Create outbound block firewall rule')) {
        New-DoHBlockRule -RuleName $RuleName -ProviderName $ProviderName -Spec $Spec -Addresses $Addresses
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
    @{ Protocol = 'TCP'; Port = 443; Label = 'DoH' }    # DNS-over-HTTPS (HTTP/1.1, HTTP/2)
    @{ Protocol = 'UDP'; Port = 443; Label = 'DoH3' }   # DNS-over-HTTPS over HTTP/3 (QUIC)
)
if ($IncludeDoT) {
    $PortSpecs += @{ Protocol = 'TCP'; Port = 853; Label = 'DoT' }  # DNS-over-TLS
    $PortSpecs += @{ Protocol = 'UDP'; Port = 853; Label = 'DoTQ' } # DNS-over-QUIC/TLS (rare)
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
    Write-Host '=== Step 1/2: Checking firewall rule configuration ===' -ForegroundColor Cyan
    Write-Host ''

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
    $ruleResults | Format-Table Provider, Label, Proto, Port, State -AutoSize

    $orphans = @(Get-ManagedFirewallRules | Where-Object { -not $expectedRuleNames.Contains($_.DisplayName) })
    if ($orphans.Count -gt 0) {
        Write-Host "WARNING: $($orphans.Count) orphan managed rule(s) present (not in current provider/port set):" -ForegroundColor Yellow
        $orphans | ForEach-Object { Write-Host "  - $($_.DisplayName)" -ForegroundColor Yellow }
    }

    $missing = @($ruleResults | Where-Object { $_.State -ne 'OK' })
    if ($missing.Count -gt 0) {
        Write-Host "WARNING: $($missing.Count) rule(s) are missing or misconfigured. Run the script without -Verify/-Remove to (re)create them." -ForegroundColor Red
    }
    else {
        Write-Host "All $($ruleResults.Count) expected rules exist with matching filters." -ForegroundColor Green
    }

    Write-Host ''
    Write-Host '=== Step 2/2: Live connectivity test (TCP only) ===' -ForegroundColor Cyan
    Write-Host "Attempting real outbound TCP connections. 'BLOCKED' = good; 'SKIP' = inconclusive." -ForegroundColor Cyan
    Write-Host ''

    $ipv6Available = Test-IPv6OutboundAvailable
    if (-not $ipv6Available) {
        Write-Host 'Host has no usable IPv6 default route/global address; IPv6 endpoints will be SKIP (inconclusive).' -ForegroundColor Yellow
        Write-Host ''
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

    $connResults | Format-Table Provider, IP, Proto, Port, Purpose, Status, Note -AutoSize

    $leaky = @($connResults | Where-Object { $_.Status -eq 'NOT BLOCKED !!' })
    $skipped = @($connResults | Where-Object { $_.Status -like 'SKIP*' })
    $blocked = @($connResults | Where-Object { $_.Status -eq 'BLOCKED (ok)' })

    Write-Host ''
    if ($leaky.Count -gt 0) {
        Write-Host "RESULT: $($leaky.Count) endpoint(s) are still REACHABLE. DoH/DoT is NOT fully blocked:" -ForegroundColor Red
        $leaky | ForEach-Object { Write-Host "  - $($_.Provider) $($_.IP):$($_.Port)/$($_.Proto)" -ForegroundColor Red }
        Write-Host 'Check that the rules exist/enabled (Step 1), that no VPN/split-tunnel bypasses the firewall, and that the correct Network Profile (Domain/Private/Public) is active.' -ForegroundColor Yellow
    }
    elseif ($blocked.Count -eq 0) {
        Write-Host "RESULT: No conclusive BLOCKED samples ($($skipped.Count) skipped). Cannot confirm blocking from live tests alone." -ForegroundColor Yellow
    }
    else {
        $msg = "RESULT: $($blocked.Count) tested TCP endpoint(s) are blocked."
        if ($skipped.Count -gt 0) {
            $msg += " ($($skipped.Count) skipped/inconclusive — not counted as pass.)"
            Write-Host $msg -ForegroundColor Yellow
        }
        else {
            Write-Host ($msg + ' DoH/DoT blocking looks good for tested endpoints.') -ForegroundColor Green
        }
    }

    $udpSpecs = @($PortSpecs | Where-Object { $_.Protocol -eq 'UDP' })
    if ($udpSpecs.Count -gt 0) {
        $udpLabels = @($udpSpecs | ForEach-Object { $_.Label }) -join ', '
        $udpPorts = @($udpSpecs | ForEach-Object { $_.Port } | Select-Object -Unique) -join ', '
        Write-Host ''
        Write-Host "NOTE: UDP rules ($udpLabels on port(s) $udpPorts) were checked for configuration only (Step 1)." -ForegroundColor Yellow
        Write-Host '      Live UDP blocking cannot be reliably verified from PowerShell (no connection handshake to test against).' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host 'Companion controls reminder: also disable browser/OS Secure DNS (DoH), and use NRPT/policy if you need org-wide DNS path control.' -ForegroundColor DarkGray
    exit 0
}

# =============================================================================
# Default action : add / reconcile the rules
# =============================================================================
Write-Host 'Adding/reconciling outbound block rules for known DoH/DoT resolvers...' -ForegroundColor Cyan

$counts = @{
    added     = 0
    updated   = 0
    unchanged = 0
}

foreach ($providerName in $Providers.Keys) {
    $ips = @($Providers[$providerName])
    foreach ($spec in $PortSpecs) {
        $ruleName = Get-RuleName -ProviderName $providerName -Spec $spec
        $result = Set-DoHBlockRuleReconciled -RuleName $ruleName -ProviderName $providerName -Spec $spec -Addresses $ips
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
    if ($PSCmdlet.ShouldProcess($orphan.DisplayName, 'Remove orphan managed DoH-Block rule')) {
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
Write-Host 'Companion controls: disable browser/OS Secure DNS (DoH); consider NRPT / DNS policy for stronger control.' -ForegroundColor DarkGray
