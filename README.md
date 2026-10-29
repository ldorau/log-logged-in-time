# Login Time Logger (Windows 11)

Background monitor that tracks how long a configured Windows account is logged in **with the screen unlocked**. Time while logged in but locked (Win+L) is excluded.

Pass two account names at install time: **AdminUsername** (owns config/logs) and **TargetUsername** (measured unlocked time; `user`, `DOMAIN\user`, or `user@upn.domain`). For testing, both may be the same account. On install, the runtime config is written under the admin profile:

`<AdministratorProfile>\LoginTimeLogger\config.json` (for example `C:\Users\AdminName\LoginTimeLogger\config.json`)

That file (and the logs) are ACL-locked to the **AdministratorProfile account + SYSTEM** (not `BUILTIN\Administrators`) so the monitored user cannot read or modify them. The startup task reads that copy.

Runs at system startup with elevated privileges (Scheduled Task as `SYSTEM`, Run level Highest).

## Requirements

- Windows 11
- PowerShell 5.1+ (built in)
- An Administrator account to install
- Admin and measured account names passed to bootstrap/install
- OpenSSH Client (`scp.exe`) when `ScpOnLockEnabled` is true — `Install.ps1` installs the Windows OpenSSH Client capability if missing
- Git for Windows when `UpdateEnabled` is true — `Install.ps1` downloads and installs it if missing

## Configure

`AdminUsername` and `TargetUsername` are **script arguments** (not required in the template before install). Optional settings remain in `config/config.json`:

```json
{
  "AdminUsername": "",
  "TargetUsername": "",
  "AdministratorProfile": "",
  "LogDirectory": "",
  "PollIntervalSeconds": 5,
  "UpdateEnabled": true,
  "UpdateRepoUrl": "https://github.com/ldorau/log-logged-in-time.git",
  "UpdateBranch": "main",
  "UpdateClonePath": "",
  "ScpOnLockEnabled": false,
  "ScpHost": "",
  "ScpUser": "",
  "ScpRemoteDirectory": "",
  "ScpPort": 22,
  "ScpIdentityFile": "",
  "ScpKnownHostsFile": ""
}
```

Account forms: `UserName`, `CONTOSO\UserName`, or `UserName@contoso.com`. Leave `LogDirectory` empty to use `<AdministratorProfile>\LoginTimeLogs` (derived from `AdminUsername` as `C:\Users\<sam>`).

Unknown lock state is treated as **locked** (fail closed). The startup task uses `-WindowStyle Hidden`. Verify lock detection with `Test-Session.ps1` while locked from another session when relying on WTS flags.

### Self-update

**On by default** (`UpdateEnabled: true`). Once per day the monitor compares the installed commit to the latest `main` tip on the allowlisted GitHub repo (`https://github.com/ldorau/log-logged-in-time.git` only). If they differ, it syncs the clone, refreshes Program Files, and restarts via the scheduled task. Offline checks retry every 10 minutes. Git for Windows is installed (Authenticode-verified) when updates are enabled. Set `UpdateEnabled: false` to disable.

### SCP on lock

**Off by default** (`ScpOnLockEnabled: false`). When enabled, each time the target session leaves unlocked-active (screen lock / away), the monitor runs `scp` to copy:

- today’s `unlocked-time-YYYY-MM-DD.log`
- `errors.log`

to `ScpUser@ScpHost:ScpRemoteDirectory/`. Uses OpenSSH `scp.exe` with key auth (`BatchMode=yes`). Defaults for empty key paths:

- `ScpIdentityFile` → `<AdministratorProfile>\LoginTimeLogger\ssh\id_ed25519`
- `ScpKnownHostsFile` → `<AdministratorProfile>\LoginTimeLogger\ssh\known_hosts`

Place a private key readable by `SYSTEM` at that path (and the matching public key on the remote). `Install.ps1` installs OpenSSH Client if `scp.exe` is missing.

## Install

### One-file bootstrap (download only `Bootstrap-Install.ps1`)

From an **elevated** PowerShell prompt (no prior clone needed):

```powershell
Set-ExecutionPolicy -Scope Process Bypass
Invoke-WebRequest `
  -Uri 'https://raw.githubusercontent.com/ldorau/log-logged-in-time/main/Bootstrap-Install.ps1' `
  -OutFile "$env:TEMP\Bootstrap-Install.ps1"
& "$env:TEMP\Bootstrap-Install.ps1" -AdminUsername AdminName -TargetUsername UserName -StartNow
```

Arguments (required, positional): **1)** `AdminUsername` — administrative account for install/config/logs; **2)** `TargetUsername` — account to measure. For testing, both may be the same account. The bootstrap installs Git if missing, clones to `%USERPROFILE%\log-logged-in-time`, then runs `scripts\Install.ps1` with those accounts. Optional: `-ClonePath`, `-Force`.

### From an existing clone

Open an **elevated** PowerShell prompt in this folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Install.ps1 -AdminUsername AdminName -TargetUsername UserName -StartNow
```

`Install.ps1` stores the runtime config under `C:\Users\<AdminUsername>\...` and points the scheduled task at that path.

## Verify lock detection

```powershell
.\scripts\Test-Session.ps1
.\scripts\Test-LockCycle.ps1   # interactive for current user; no Admin files
.\scripts\Test-WtsLockProbe.ps1  # one-account WTS probe (Win+L; no second session)
```

## Status / logs

```powershell
.\scripts\Status.ps1
.\scripts\Get-LockedTime.ps1          # estimate locked/away time from log transitions
.\scripts\Get-LockedTime.ps1 -AllDays
```

**Unlocked-time logs** (when the target user was logged in with the screen unlocked):

`C:\Users\AdminName\LoginTimeLogs\` (example when `AdministratorProfile` is `C:\Users\AdminName`)

That is `LogDirectory` from config, or `<AdministratorProfile>\LoginTimeLogs` when `LogDirectory` is empty.

| File | Contents |
|------|----------|
| `unlocked-time-YYYY-MM-DD.log` | Lock/unlock transitions, heartbeats, day total |
| `unlocked-time-summary.csv` | One row per completed day |
| `state.json` | Running total for the current day |
| `service.log` | Monitor diagnostics |

**Error log** (install, monitor, and helper failures — separate from the daily time logs):

`<AdministratorProfile>\LoginTimeLogger\errors.log` (example: `C:\Users\AdminName\LoginTimeLogger\errors.log`)

Errors are also printed to the screen. If that path is not writable, a fallback is used: `%TEMP%\LoginTimeLogger\errors.log`.

## Uninstall

```powershell
.\scripts\Uninstall.ps1
# also delete logs:
.\scripts\Uninstall.ps1 -RemoveLogs
```

## How unlocked time is measured

Every few seconds the monitor calls Windows Terminal Services APIs (`WTSEnumerateSessions` / `WTSSessionInfoEx`) for sessions owned by `TargetUsername` from the config file. Seconds are counted only when that session is **Active** and **not locked**.

Gaps larger than a short cap (sleep/hibernate) are not credited as unlocked time.

## Notes

- Use a real account id (SAM / `DOMAIN\user` / UPN), not a display name.
- Standard users cannot change the scheduled task or the log ACL without Administrator rights.
- Supported on **Windows 11 Home**. Pass `-AdminUsername` for a real elevated user (for example `AdminName` → `C:\Users\AdminName`). The built-in Administrator account is not required.
- See `INSTALL.txt` for a full plain-text install guide.
