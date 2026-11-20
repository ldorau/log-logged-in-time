# Browser history files

LoginTimeLogger can export Chromium-family History databases for the measured
target user, write dated CSVs under `LogDirectory\bhist\`, and upload them via
SCP. Brand names are scrubbed in staged leaf names (`op` / `ch` profile tags).

## Local layout

| Path | Role |
|------|------|
| `LogDirectory\bhist\log-history-op-<profile>-YYYY-MM-DD.csv` | Dated visit CSV for an `op` profile |
| `LogDirectory\bhist\log-history-ch-<profile>-YYYY-MM-DD.csv` | Dated visit CSV for a `ch` profile |
| Staged `log-history-op-<profile>` / `log-history-ch-<profile>` | Shared-read copies of the live History DB (TEMP or under `LogDirectory` for manual SCP) |

`<profile>` is a filesystem-safe profile id (`Default`, `Profile-1`, …). CSVs are
produced by `scripts/Convert-LogBhToCsv.ps1` (`-PreviousDays 1` for the periodic
and on-lock paths).

## When files are produced / uploaded

### 1-minute cycle

When `ScpHost` / `ScpUser` / `ScpRemoteDirectory` are set, the monitor (in order):

1. Restarts `LoginTimeLoggerLockSignal` if the lock-signal file is stale/missing
2. Writes a `HEARTBEAT` line to today’s unlocked-time log
3. Uploads today’s `unlocked-time-yyyy-MM-dd.log`
4. Exchanges remote `commands.txt`

### 5-minute cycle

Converts today’s History DBs and uploads every current-date CSV under
`LogDirectory\bhist\` (not the unlocked-time log; that is on the 1-minute cycle).

### SCP on lock

When `ScpOnLockEnabled` is true, lock-time SCP also converts and uploads today’s
`log-history-*-YYYY-MM-DD.csv` files (along with the usual unlocked-time logs,
error logs, and `service.log`).

### Manual fuller upload

```powershell
.\scripts\Copy-LogsViaScp.ps1 -Force
```

Refreshes today’s history CSVs, then uploads every `*.csv` under `LogDirectory`
(recursive, including all `bhist` files and `unlocked-time-summary.csv`), plus
raw staged History DBs (`log-history-op-*` / `log-history-ch-*`) for every
discovered profile.

## Related scripts

| Script | Role |
|--------|------|
| `scripts/Convert-LogBhToCsv.ps1` | History DB → dated CSV |
| `scripts/Copy-LogsViaScp.ps1` | Manual SCP including all CSVs + raw History |
| `scripts/Test-ScpOnLock.ps1` | SCP probe; can stage raw History for a test copy |
