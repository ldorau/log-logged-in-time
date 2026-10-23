# Login Time Logger (Windows 11)

Background monitor that tracks how long a configured Windows account is logged in **with the screen unlocked**. Time while logged in but locked (Win+L) is excluded.

Set the account to measure in the project template `config/config.json` as `TargetUsername` (`user`, `DOMAIN\user`, or `user@upn.domain`). On install, the runtime config is written to the **Administrator** profile:

`C:\Users\Administrator\LoginTimeLogger\config.json`

That file (and the logs) are ACL-locked so the monitored user cannot read or modify them. The startup task reads the Administrator copy.

Runs at system startup with elevated privileges (Scheduled Task as `SYSTEM`, Run level Highest).

## Requirements

- Windows 11
- PowerShell 5.1+ (built in)
- An Administrator account to install
- `TargetUsername` set in `config/config.json` before install

## Configure

Edit `config/config.json`:

```json
{
  "TargetUsername": "jsmith",
  "AdministratorProfile": "C:\\Users\\Administrator",
  "LogDirectory": "",
  "PollIntervalSeconds": 5,
  "UpdateEnabled": false,
  "UpdateRepoUrl": "https://github.com/ldorau/log-logged-in-time.git",
  "UpdateBranch": "main",
  "UpdateClonePath": ""
}
```

`TargetUsername` is required (`jsmith`, `CONTOSO\jsmith`, or `jsmith@contoso.com`). Leave `LogDirectory` empty to use `<AdministratorProfile>\LoginTimeLogs`.

Unknown lock state is treated as **locked** (fail closed). The startup task uses `-WindowStyle Hidden`. Verify lock detection with `Test-Session.ps1` while locked from another session when relying on WTS flags.

### Self-update

**Off by default** (`UpdateEnabled: false`). When enabled, once per day the monitor compares the installed commit to the latest `main` tip on the allowlisted GitHub repo (`https://github.com/ldorau/log-logged-in-time.git` only). If they differ, it syncs the clone, refreshes Program Files, and restarts via the scheduled task. Offline checks retry every 10 minutes. Git for Windows is installed (Authenticode-verified) only when updates are enabled.

## Install

Open an **elevated** PowerShell prompt in this folder:

```powershell
Set-ExecutionPolicy -Scope Process Bypass
.\scripts\Install.ps1 -StartNow
```

`Install.ps1` reads the project template `config/config.json` (without modifying it), then stores the runtime config under the Administrator profile and points the task at that path.

## Verify lock detection

```powershell
.\scripts\Test-Session.ps1
.\scripts\Test-LockCycle.ps1   # interactive for current user; no Admin files
```

## Status / logs

```powershell
.\scripts\Status.ps1
```

Log files (Administrator only), under `LogDirectory` (default `<AdministratorProfile>\LoginTimeLogs`):

| File | Contents |
|------|----------|
| `unlocked-time-YYYY-MM-DD.log` | Lock/unlock transitions, heartbeats, day total |
| `unlocked-time-summary.csv` | One row per completed day |
| `state.json` | Running total for the current day |
| `service.log` | Monitor diagnostics |

**Error log** (install, monitor, and helper failures — separate from the daily time logs):

`C:\Users\Administrator\LoginTimeLogger\errors.log`

That is `<AdministratorProfile>\LoginTimeLogger\errors.log`. If `AdministratorProfile` in config points elsewhere, the error log follows that path. Errors are also printed to the screen. If the Administrator path is not writable, a fallback is used: `%TEMP%\LoginTimeLogger\errors.log`.

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
- Supported on **Windows 11 Home**. Caveat: the default path is `C:\Users\Administrator\...`, but that profile often does not exist on Home until the built-in Administrator account is enabled. Before install, set `AdministratorProfile` in `config/config.json` to a real administrator user’s profile (for example `C:\Users\YourAdminName`).
- See `INSTALL.txt` for a full plain-text install guide.
