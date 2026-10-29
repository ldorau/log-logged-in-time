Login Time Logger (Windows 11)
==============================

Background monitor that tracks how long a configured Windows account is logged
in with the screen unlocked. Time while logged in but the screen is locked
(Win+L) is not counted.

Pass AdminUsername (install owner) and TargetUsername (measured user) to
bootstrap/install. For testing, both may be the same account. Runtime config
is stored under the admin profile, e.g.:
  C:\Users\AdminName\LoginTimeLogger\config.json
ACL: that admin account + SYSTEM (not BUILTIN\Administrators); task reads from there.

The monitor starts at system startup with elevated privileges (Scheduled Task
running as SYSTEM, Run level Highest). Log files are stored under the
Administrator profile and protected with ACLs so the monitored account cannot
read or modify them.


Requirements
------------
- Windows 11
- PowerShell 5.1 or later (included with Windows)
- An Administrator account to install and view logs
- AdminUsername and TargetUsername passed to bootstrap/install
- OpenSSH Client (scp.exe) when ScpOnLockEnabled=true
  (Install.ps1 installs the Windows capability if missing)
- Git for Windows when UpdateEnabled=true
  (Install.ps1 downloads and installs it if missing)


Installation
------------
One-file bootstrap (download only Bootstrap-Install.ps1 from GitHub):
  Elevated PowerShell:
    Set-ExecutionPolicy -Scope Process Bypass
    Invoke-WebRequest -Uri "https://raw.githubusercontent.com/ldorau/log-logged-in-time/main/Bootstrap-Install.ps1" -OutFile "$env:TEMP\Bootstrap-Install.ps1"
    & "$env:TEMP\Bootstrap-Install.ps1" -AdminUsername AdminName -TargetUsername UserName -StartNow
  Args: (1) admin account (2) measured user (may be the same for testing).
  Installs Git if needed, clones, runs Install.ps1.

From an existing clone:
  .\scripts\Install.ps1 -AdminUsername AdminName -TargetUsername UserName -StartNow
  Follow INSTALL.txt for status/uninstall. Optional: .\scripts\Test-LockCycle.ps1


How unlocked time is measured
-----------------------------
Every few seconds the monitor queries Windows Terminal Services APIs
(WTSEnumerateSessions / WTSSessionInfoEx) for sessions owned by TargetUsername
from the config file. Time is counted only when that session is Active and
not locked.

Gaps caused by sleep or hibernate are capped so they are not credited as
unlocked time.


Log files (admin profile only)
------------------------------
Default location (example AdministratorProfile=C:\Users\AdminName):
  C:\Users\AdminName\LoginTimeLogs

  unlocked-time-YYYY-MM-DD.log  - lock/unlock transitions, heartbeats, day total
  unlocked-time-summary.csv     - one row per completed day
  state.json                    - running total for the current day
  service.log                   - monitor diagnostics

Error log (same admin profile; separate from daily time logs):
  C:\Users\AdminName\LoginTimeLogger\errors.log
  All script errors/warnings are printed to the screen and appended here.

Self-update (on by default; UpdateEnabled=true):
  When online, compares allowlisted GitHub tip to
  C:\Program Files\LoginTimeLogger\installed-commit.txt
  If different: sync LoginTimeLogger\repo, refresh Program Files, restart
  via the scheduled task. Offline: retry in 10 minutes.
  Git for Windows is installed (Authenticode-checked) when UpdateEnabled=true.
  Set UpdateEnabled=false to disable.

SCP on lock (opt-in; ScpOnLockEnabled=false by default):
  When enabled, on each lock copies today's unlocked-time log and errors.log
  via OpenSSH scp to ScpUser@ScpHost:ScpRemoteDirectory/ using an SSH key
  (default <AdministratorProfile>\LoginTimeLogger\ssh\id_ed25519).


Project layout
--------------
  Bootstrap-Install.ps1       - one-file bootstrap (Git + clone + Install.ps1)
  config\config.json          - optional settings template (accounts are CLI args)
  src\LoginTimeLogger.ps1     - background monitor (reads runtime config)
  src\SessionQuery.cs         - session/lock detection helpers
  src\Update-Check.ps1        - daily GitHub self-update helper
  src\Scp-OnLock.ps1          - copy time + error logs via scp on lock
  scripts\Install.ps1         - installs task; writes runtime config under Administrator
  scripts\Uninstall.ps1       - remove scheduled task
  scripts\Status.ps1          - show task state and today's total
  scripts\Get-LockedTime.ps1  - estimate locked/away time from daily logs
  scripts\Test-Session.ps1    - list sessions / test unlock detection
  scripts\Test-LockCycle.ps1  - lock/unlock calibration for current user
  scripts\Test-WtsLockProbe.ps1 - one-account WTS lock probe (Win+L)
  scripts\WtsLockProbe.ps1    - background worker for Test-WtsLockProbe
  scripts\Invoke-UnlockedTimeInvestigation.ps1 - two-account investigation
  scripts\Invoke-UnlockedTimeInvestigation-OneAccount.ps1 - one-account investigation
  src\Common-Error.ps1        - screen + Administrator errors.log helper
  INSTALL.txt                 - installation guide
  README.txt                  - this file


Notes
-----
- Account args: local SAM, DOMAIN\user, or user@upn.domain
  (not the display name). Unknown lock state is treated as locked
  (fail closed — time is not counted).
- Supported on Windows 11 Home. Pass -AdminUsername for a real elevated
  user (for example AdminName -> C:\Users\AdminName). The built-in
  Administrator account / BUILTIN\Administrators group is not required.
- Standard users cannot change the scheduled task or the log ACL without
  Administrator rights.
