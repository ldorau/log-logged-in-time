# Extras: DNS forcing, DoH/DoT, and VPN firewall helpers

Optional helpers under `scripts/`. They are not part of the core LoginTimeLogger
time-tracking flow documented in the main README. Elevation required for
add/remove (verify can run without elevation for DoH/VPN).

| Script | Role |
|--------|------|
| `scripts/Force-DnsToLocalResolver.ps1` | Point eligible adapters at a LAN DNS resolver and block outbound classic DNS (TCP/UDP 53) to everywhere else (IPv6 DNS blocked too). Managed rules use the `DNS-Force:` prefix. |
| `scripts/Block-DoH-Firewall.ps1` | Block outbound DoH/DoT to known public encrypted-DNS resolver IPs. Managed rules use the `DoH-Block:` prefix. Provider list: `scripts/Block-DoH-Providers.json` (or embedded defaults). |
| `scripts/Block-Vpn-Firewall.ps1` | Block outbound traffic to known commercial VPN endpoints on classic VPN ports (and 443 when enabled). Managed rules use the `VPN-Block:` prefix. Provider list: `scripts/Block-Vpn-Providers.json`. |

Forcing plain DNS to a LAN resolver does not stop browsers from using DoH/DoT
on 443/853; the DoH helper does not replace port-53 forcing. VPN blocking is
IP-list based and cannot stop every stealth/CDN VPN.

## Force-DnsToLocalResolver.ps1

Windows Firewall cannot DNAT DNS packets. This script:

1. Sets eligible up Ethernet/Wi-Fi adapters’ DNS server list to `-DnsServer` (IPv4).
2. Adds outbound **Block** rules for TCP/UDP 53 to all IPv4 ranges except that IP, plus IPv6 DNS blocks.

Set `ServerDNS` (IPv4) in the LoginTimeLogger runtime config. The daily update
check and Status use that value; there is no hardcoded default IP in the scripts.

```powershell
# Elevated PowerShell, from repo root (or Program Files\LoginTimeLogger\scripts):
.\scripts\Force-DnsToLocalResolver.ps1 -DnsServer <LAN-resolver-IPv4>
.\scripts\Force-DnsToLocalResolver.ps1 -ConfigPath "$env:USERPROFILE\LoginTimeLogger\config.json"
.\scripts\Force-DnsToLocalResolver.ps1 -DnsServer <LAN-resolver-IPv4> -Verify
.\scripts\Force-DnsToLocalResolver.ps1 -Remove -RestoreDnsToDhcp
```

Useful parameters: `-ConfigPath` (reads `ServerDNS`), `-InterfaceAlias`, `-Quiet` (with `-Verify`; exit 0 = OK, 1 = FAIL), `-WhatIf`. Daily reconcile is skipped when `ServerDNS` is empty.

## Block-DoH-Firewall.ps1

Creates one outbound block rule per provider / protocol / port (TCP/UDP 443 DoH/DoH3; TCP/UDP 853 DoT when `-IncludeDoT` is true, the default). Reconciles drift and removes orphan `DoH-Block:` rules.

```powershell
.\scripts\Block-DoH-Firewall.ps1
.\scripts\Block-DoH-Firewall.ps1 -WhatIf
.\scripts\Block-DoH-Firewall.ps1 -Verify
.\scripts\Block-DoH-Firewall.ps1 -Remove
```

`-Verify` checks rule filters, then live TCP probes (UDP rules are config-only). Exit codes with `-Quiet`: `0` blocked, `1` leak/misconfigured, `2` inconclusive.

Firewall IP blocks alone are not enough for “no DoH anywhere”: also disable browser/OS Secure DNS, and consider NRPT/policy if you need org-wide path control. Update `Block-DoH-Providers.json` when public resolver IPs change.

## Block-Vpn-Firewall.ps1

Creates outbound **Block** rules per provider / protocol / port for known VPN
endpoints (`VPN-Block:` prefix). Default ports to each listed IP:

- UDP/TCP 1194 (OpenVPN)
- UDP 51820 (WireGuard)
- UDP 500 / 4500 (IKE / IPsec NAT-T)
- TCP 1723 (PPTP)
- TCP/UDP 443 when `-IncludeHttps` is true (default)

```powershell
.\scripts\Block-Vpn-Firewall.ps1
.\scripts\Block-Vpn-Firewall.ps1 -WhatIf
.\scripts\Block-Vpn-Firewall.ps1 -Verify
.\scripts\Block-Vpn-Firewall.ps1 -IncludeHttps:$false
.\scripts\Block-Vpn-Firewall.ps1 -Remove
```

`-Verify` checks rule filters, then live TCP probes (UDP config-only). Exit codes match the DoH helper (`0` / `1` / `2`).

Provider IPs change frequently — edit `Block-Vpn-Providers.json`. This cannot
block arbitrary self-hosted VPNs or endpoints missing from the list.

## Allow-ScpOutboundFirewall.ps1

Creates/reconciles an outbound **Allow** rule for TCP to `ScpHost:ScpPort` (prefix `SCP-Allow:`). Used when SCP-on-lock needs an explicit allow alongside tighter outbound policies.

```powershell
.\scripts\Allow-ScpOutboundFirewall.ps1 -RemoteHost <host> -RemotePort 22
.\scripts\Allow-ScpOutboundFirewall.ps1 -ConfigPath "$env:USERPROFILE\LoginTimeLogger\config.json"
.\scripts\Allow-ScpOutboundFirewall.ps1 -RemoteHost <host> -Verify
.\scripts\Allow-ScpOutboundFirewall.ps1 -Remove
```

When `ScpOnLockEnabled` is true and `ScpHost` is set, Install and the daily self-update check run this helper. `Status.ps1` reports `SCP-Allow: OK/FAIL` in that case.

## How LoginTimeLogger may invoke them

When self-update is enabled, after each successful **daily** update check the monitor may run these scripts as child processes (from the update clone or `Program Files\LoginTimeLogger\scripts`). `Status.ps1` can also report DNS-Force / DNS-over-HTTP / VPN-Block / SCP-Allow results when the scripts are present.

Manual runs remain supported for machines that are not using the daily hook.
