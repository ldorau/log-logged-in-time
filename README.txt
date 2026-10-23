Login Time Logger (Windows 11)
==============================

Background monitor that tracks how long a configured Windows account is logged
in with the screen unlocked. Time while logged in but the screen is locked
(Win+L) is not counted.

Set TargetUsername (Windows logon / SAM name) in this project's
config\config.json before install. The installer copies the runtime config to
the Administrator profile:
  C:\Users\Administrator\LoginTimeLogger\config.json
That file is ACL-protected like the logs; the scheduled task reads from there.

The monitor starts at system startup with elevated privileges (Scheduled Task
running as SYSTEM, Run level Highest). Log files are stored under the
Administrator profile and protected with ACLs so the monitored account cannot
read or modify them.


Requirements
------------
- Windows 11
- PowerShell 5.1 or later (included with Windows)
- An Administrator account to install and view logs
- TargetUsername set in config\config.json before install


Installation
------------
1. Edit config\config.json and set TargetUsername
   (local SAM, DOMAIN\user, or user@upn.domain).
2. Follow INSTALL.txt for install, status, and uninstall steps.
3. Optional calibration: .\scripts\Test-LockCycle.ps1
   (current user; Win+L cycle; no Administrator files).


How unlocked time is measured
-----------------------------
Every few seconds the monitor queries Windows Terminal Services APIs
(WTSEnumerateSessions / WTSSessionInfoEx) for sessions owned by TargetUsername
from the config file. Time is counted only when that session is Active and
not locked.

Gaps caused by sleep or hibernate are capped so they are not credited as
unlocked time.


Log files (Administrator only)
------------------------------
Default location:
  C:\Users\Administrator\LoginTimeLogs

  unlocked-time-YYYY-MM-DD.log  - lock/unlock transitions, heartbeats, day total
  unlocked-time-summary.csv     - one row per completed day
  state.json                    - running total for the current day
  service.log                   - monitor diagnostics

Error log (Administrator only; separate from daily time logs):
  C:\Users\Administrator\LoginTimeLogger\errors.log
  All script errors/warnings are printed to the screen and appended here.

Self-update (opt-in; UpdateEnabled=false by default):
  When enabled and online, compares allowlisted GitHub tip to
  C:\Program Files\LoginTimeLogger\installed-commit.txt
  If different: sync LoginTimeLogger\repo, refresh Program Files, restart
  via the scheduled task. Offline: retry in 10 minutes.
  Git for Windows is installed (Authenticode-checked) only if UpdateEnabled=true.


Project layout
--------------
  config\config.json          - install template (edit TargetUsername here)
  src\LoginTimeLogger.ps1     - background monitor (reads runtime config)
  src\SessionQuery.cs         - session/lock detection helpers
  src\Update-Check.ps1        - daily GitHub self-update helper
  scripts\Install.ps1         - installs task; writes runtime config under Administrator
  scripts\Uninstall.ps1       - remove scheduled task
  scripts\Status.ps1          - show task state and today's total
  scripts\Test-Session.ps1    - list sessions / test unlock detection
  scripts\Test-LockCycle.ps1  - lock/unlock calibration for current user
  src\Common-Error.ps1        - screen + Administrator errors.log helper
  INSTALL.txt                 - installation guide
  README.txt                  - this file


Notes
-----
- TargetUsername: local SAM, DOMAIN\user, or user@upn.domain
  (not the display name). Unknown lock state is treated as locked
  (fail closed — time is not counted).
- Supported on Windows 11 Home. Caveat: the default path is
  C:\Users\Administrator\... but that profile often does not exist on
  Home until the built-in Administrator account is enabled. Before
  install, set AdministratorProfile in config\config.json to a real
  administrator user's profile (for example C:\Users\YourAdminName).
- If the Administrator profile path differs on your PC for any reason,
  set AdministratorProfile in config\config.json before installing.
- Standard users cannot change the scheduled task or the log ACL without
  Administrator rights.
