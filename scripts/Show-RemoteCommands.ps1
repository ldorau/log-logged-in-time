#Requires -Version 5.1
<#
.SYNOPSIS
  Prints every remote commands.txt command with arguments and description.
.DESCRIPTION
  Documents the verbs the monitor accepts in ScpRemoteDirectory/commands.txt
  (downloaded each 1-minute commands cycle). One command per line; blank lines and
  # comments are ignored. Does not contact the remote host.
.EXAMPLE
  .\scripts\Show-RemoteCommands.ps1
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$commands = @(
    [pscustomobject]@{
        Command     = 'update'
        Arguments   = '(none)'
        Description = 'Force-sync the update clone (git fetch + reset --hard), log git log -1 --oneline in the commands-run transcript, always publish into Program Files from the synced clone, then restart the monitor.'
    }
    [pscustomobject]@{
        Command     = 'restart'
        Arguments   = '(none)'
        Description = 'Restart the LoginTimeLogger scheduled task (release mutex, delayed Start-ScheduledTask, exit). Runs after remote clear / email when queued with other commands; if update also runs and publishes, that restart covers it.'
    }
    [pscustomobject]@{
        Command     = 'reset'
        Arguments   = '(none)'
        Description = 'Set today''s cumulative unlocked time (state.json UnlockedSecondsToday) to 0. Writes a CUMULATIVE_RESET line to the unlocked-time day log. Same semantics as Reset-CumulativeTime.ps1 with no TIME.'
    }
    [pscustomobject]@{
        Command     = 'reset'
        Arguments   = 'TIME'
        Description = 'Set today''s cumulative unlocked time to TIME. TIME is HH:MM:SS (hours may exceed 24) or whole seconds (e.g. 01:30:00 or 5400). Logs CUMULATIVE_SET (or CUMULATIVE_RESET if TIME is 0).'
    }
    [pscustomobject]@{
        Command     = 'reset'
        Arguments   = '+TIME'
        Description = 'Add TIME to today''s cumulative unlocked time. TIME is HH:MM:SS or whole seconds (e.g. +00:15:00 or +600). Logs CUMULATIVE_ADD.'
    }
    [pscustomobject]@{
        Command     = 'reset'
        Arguments   = '-TIME'
        Description = 'Subtract TIME from today''s cumulative unlocked time (floored at 0). TIME is HH:MM:SS or whole seconds (e.g. -00:10:00 or -600). Logs CUMULATIVE_DEC.'
    }
    [pscustomobject]@{
        Command     = 'break'
        Arguments   = '(none)'
        Description = 'Show a topmost countdown on the target user''s desktop (message "PRZERWA! - chodź do nas!", current cumulative unlocked time, 5s timer), then lock the screen - same flow as the unlock-quota warning, different message. Ignored when the target session is already locked (commands-run email still sent).'
    }
    [pscustomobject]@{
        Command     = 'disable-break'
        Arguments   = '(none)'
        Description = 'Disable the hourly forced rest (Twoje oczy unlock-quota + minimum 5 min of actual locked screen time) for the current calendar day only. Cleared automatically at midnight / next day rollover so forced breaks resume without another command. Cancels any in-progress minimum-break lock window.'
    }
    [pscustomobject]@{
        Command     = 'setUnlockQuotaEnabled'
        Arguments   = '[true|false]'
        Description = 'Persist UnlockQuotaEnabled in the installed runtime config.json and apply it live (no restart). Omitting the argument defaults to true. false turns off hourly Twoje-oczy forced locks until set true again (also cancels any in-progress minimum-break window). Unlike disable-break, this survives day rollover.'
    }
)

Write-Host 'Remote commands.txt verbs (one command per line on the remote host)' -ForegroundColor Cyan
Write-Host 'File: ScpUser@ScpHost:ScpRemoteDirectory/commands.txt' -ForegroundColor DarkGray
Write-Host 'Format: <command> [arg1] [arg2] ...' -ForegroundColor DarkGray
Write-Host 'Ignored: blank lines and lines starting with #' -ForegroundColor DarkGray
Write-Host ''

$i = 0
foreach ($c in $commands) {
    $i++
    Write-Host ('{0}. {1} {2}' -f $i, $c.Command, $c.Arguments) -ForegroundColor Yellow
    Write-Host ('   {0}' -f $c.Description)
    Write-Host ''
}

Write-Host 'Examples (remote commands.txt content):' -ForegroundColor Cyan
Write-Host '  update'
Write-Host '  restart'
Write-Host '  reset'
Write-Host '  reset 01:30:00'
Write-Host '  reset +00:15:00'
Write-Host '  reset -00:10:00'
Write-Host '  break'
Write-Host '  disable-break'
Write-Host '  setUnlockQuotaEnabled'
Write-Host '  setUnlockQuotaEnabled false'
Write-Host '  setUnlockQuotaEnabled true'
Write-Host '  update'
Write-Host '  reset 0'
