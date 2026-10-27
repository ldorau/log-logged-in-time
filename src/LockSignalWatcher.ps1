#Requires -Version 5.1
<#
.SYNOPSIS
  User-context SessionSwitch watcher that writes lock state for LoginTimeLogger.
.DESCRIPTION
  Runs in the interactive target user session (STA). Listens to
  SystemEvents.SessionSwitch and heartbeats a small JSON file that SessionQuery
  reads from SYSTEM. This covers Win+L when WTS SessionFlags and OpenInputDesktop
  stay wrong and Security 4800/4801 audit is unavailable.
#>
param(
    [Parameter(Mandatory)][string]$TargetUsername,
    [Parameter(Mandatory)][string]$SignalPath,
    [int]$HeartbeatSeconds = 30
)

$ErrorActionPreference = 'Stop'

if ($HeartbeatSeconds -lt 5) {
    $HeartbeatSeconds = 5
}

$signalDir = Split-Path -Parent $SignalPath
if (-not (Test-Path -LiteralPath $signalDir)) {
    New-Item -ItemType Directory -Path $signalDir -Force | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ('LoginTimeLockSignalWatch' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Windows.Forms') -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Text;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

public static class LoginTimeLockSignalWatch
{
    private static readonly object Sync = new object();
    private static string s_path;
    private static string s_target;
    private static bool s_locked;
    private static string s_reason = "Start";

    public static void Run(string path, string targetUsername, int heartbeatMs)
    {
        s_path = path;
        s_target = targetUsername ?? string.Empty;
        s_locked = false;
        s_reason = "Start";
        WriteSignal();

        SessionSwitchEventHandler handler = (sender, e) =>
        {
            lock (Sync)
            {
                switch (e.Reason)
                {
                    case SessionSwitchReason.SessionLock:
                        s_locked = true;
                        s_reason = e.Reason.ToString();
                        WriteSignal();
                        break;
                    case SessionSwitchReason.SessionUnlock:
                        s_locked = false;
                        s_reason = e.Reason.ToString();
                        WriteSignal();
                        break;
                    case SessionSwitchReason.SessionLogoff:
                        s_locked = true;
                        s_reason = e.Reason.ToString();
                        WriteSignal();
                        break;
                    case SessionSwitchReason.ConsoleConnect:
                    case SessionSwitchReason.RemoteConnect:
                    case SessionSwitchReason.SessionLogon:
                        s_locked = false;
                        s_reason = e.Reason.ToString();
                        WriteSignal();
                        break;
                    default:
                        s_reason = "Heartbeat:" + e.Reason.ToString();
                        WriteSignal();
                        break;
                }
            }
        };

        SystemEvents.SessionSwitch += handler;
        try
        {
            while (true)
            {
                int start = Environment.TickCount;
                while ((Environment.TickCount - start) < heartbeatMs)
                {
                    Application.DoEvents();
                    Thread.Sleep(50);
                }

                // Refresh UpdatedUtc so SessionQuery can detect a dead watcher.
                lock (Sync)
                {
                    WriteSignal();
                }
            }
        }
        finally
        {
            SystemEvents.SessionSwitch -= handler;
        }
    }

    private static void WriteSignal()
    {
        DateTime nowLocal = DateTime.Now;
        DateTime nowUtc = DateTime.UtcNow;
        string json =
            "{" +
            "\"TargetUsername\":\"" + Escape(s_target) + "\"," +
            "\"Locked\":" + (s_locked ? "true" : "false") + "," +
            "\"Reason\":\"" + Escape(s_reason) + "\"," +
            "\"UpdatedLocal\":\"" + Escape(nowLocal.ToString("yyyy-MM-dd HH:mm:ss")) + "\"," +
            "\"UpdatedUtc\":\"" + Escape(nowUtc.ToString("o")) + "\"," +
            "\"Source\":\"SessionSwitch\"" +
            "}";

        string dir = Path.GetDirectoryName(s_path);
        if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
        {
            Directory.CreateDirectory(dir);
        }

        string tmp = s_path + ".tmp";
        File.WriteAllText(tmp, json, new UTF8Encoding(false));
        try
        {
            if (File.Exists(s_path))
            {
                File.Delete(s_path);
            }
        }
        catch
        {
            // replace below
        }

        try
        {
            File.Move(tmp, s_path);
        }
        catch
        {
            File.Copy(tmp, s_path, true);
            try { File.Delete(tmp); } catch { }
        }
    }

    private static string Escape(string value)
    {
        if (string.IsNullOrEmpty(value))
        {
            return string.Empty;
        }

        return value.Replace("\\", "\\\\").Replace("\"", "\\\"");
    }
}
'@
}

try {
    [LoginTimeLockSignalWatch]::Run($SignalPath, $TargetUsername, ($HeartbeatSeconds * 1000))
    exit 0
}
catch {
    $msg = '{0:yyyy-MM-dd HH:mm:ss} LockSignalWatcher ERROR: {1}' -f (Get-Date), $_.Exception.ToString()
    [Console]::Error.WriteLine($msg)
    try {
        $errPath = [System.IO.Path]::ChangeExtension($SignalPath, '.watcher-error.log')
        Add-Content -LiteralPath $errPath -Value $msg -Encoding UTF8
    }
    catch { }
    exit 1
}
