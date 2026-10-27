#Requires -Version 5.1
<#
.SYNOPSIS
  User-context SessionSwitch watcher that writes lock state for LoginTimeLogger.
.DESCRIPTION
  Runs in the interactive target user session (STA). Listens to
  SystemEvents.SessionSwitch and heartbeats a small JSON file that SessionQuery
  reads from SYSTEM. Survives Task Scheduler console-control (0xC000013A) by
  ignoring CTRL_C/CTRL_CLOSE and restarting the message loop on unexpected exit.
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

$watcherLogPath = [System.IO.Path]::ChangeExtension($SignalPath, '.watcher.log')
$watcherErrPath = [System.IO.Path]::ChangeExtension($SignalPath, '.watcher-error.log')

function Write-WatcherLog {
    param([string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $Message
    try { Add-Content -LiteralPath $watcherLogPath -Value $line -Encoding UTF8 } catch { }
    try { [Console]::Error.WriteLine($line) } catch { }
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ('LoginTimeLockSignalWatch' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Windows.Forms', 'System.Drawing') -Language CSharp -TypeDefinition @'
using System;
using System.Drawing;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Windows.Forms;
using Microsoft.Win32;

public static class LoginTimeLockSignalWatch
{
    private const uint CTRL_C_EVENT = 0;
    private const uint CTRL_BREAK_EVENT = 1;
    private const uint CTRL_CLOSE_EVENT = 2;
    private const uint CTRL_LOGOFF_EVENT = 5;
    private const uint CTRL_SHUTDOWN_EVENT = 6;

    private static readonly object Sync = new object();
    private static string s_path;
    private static string s_target;
    private static bool s_locked;
    private static string s_reason = "Start";
    private static ConsoleCtrlDelegate s_ctrlHandler;
    private static Form s_form;
    private static System.Windows.Forms.Timer s_timer;
    private static SessionSwitchEventHandler s_sessionHandler;

    private delegate bool ConsoleCtrlDelegate(uint ctrlType);

    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern bool SetConsoleCtrlHandler(ConsoleCtrlDelegate handler, bool add);

    public static void Run(string path, string targetUsername, int heartbeatMs)
    {
        s_path = path;
        s_target = targetUsername ?? string.Empty;
        s_locked = false;
        s_reason = "Start";

        // Task Scheduler often delivers CTRL_CLOSE / CTRL_C (exit 0xC000013A). Swallow those.
        s_ctrlHandler = OnConsoleCtrl;
        SetConsoleCtrlHandler(s_ctrlHandler, true);

        WriteSignal();

        s_sessionHandler = OnSessionSwitch;
        SystemEvents.SessionSwitch += s_sessionHandler;

        s_form = new Form();
        s_form.Text = "LoginTimeLoggerLockSignal";
        s_form.ShowInTaskbar = false;
        s_form.FormBorderStyle = FormBorderStyle.FixedToolWindow;
        s_form.Opacity = 0;
        s_form.Size = new Size(0, 0);
        s_form.StartPosition = FormStartPosition.Manual;
        s_form.Location = new Point(-32000, -32000);
        s_form.Load += delegate { s_form.Hide(); };
        s_form.FormClosing += OnFormClosing;

        s_timer = new System.Windows.Forms.Timer();
        s_timer.Interval = Math.Max(5000, heartbeatMs);
        s_timer.Tick += OnHeartbeatTick;
        s_timer.Start();

        try
        {
            Application.Run(s_form);
        }
        finally
        {
            Cleanup();
        }
    }

    private static bool OnConsoleCtrl(uint ctrlType)
    {
        if (ctrlType == CTRL_C_EVENT || ctrlType == CTRL_BREAK_EVENT || ctrlType == CTRL_CLOSE_EVENT)
        {
            // Keep running under Task Scheduler / hidden console teardown.
            return true;
        }

        if (ctrlType == CTRL_LOGOFF_EVENT || ctrlType == CTRL_SHUTDOWN_EVENT)
        {
            lock (Sync)
            {
                s_locked = true;
                s_reason = "ConsoleCtrl:" + ctrlType;
                try { WriteSignal(); } catch { }
            }
            // Allow process exit on real logoff/shutdown.
            return false;
        }

        return false;
    }

    private static void OnSessionSwitch(object sender, SessionSwitchEventArgs e)
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
                    s_reason = "SessionSwitch:" + e.Reason.ToString();
                    WriteSignal();
                    break;
            }
        }
    }

    private static void OnHeartbeatTick(object sender, EventArgs e)
    {
        lock (Sync)
        {
            WriteSignal();
        }
    }

    private static void OnFormClosing(object sender, FormClosingEventArgs e)
    {
        // Ignore user/task host trying to close the hidden form; keep the pump alive.
        if (e.CloseReason == CloseReason.UserClosing ||
            e.CloseReason == CloseReason.TaskManagerClosing ||
            e.CloseReason == CloseReason.ApplicationExitCall)
        {
            e.Cancel = true;
            try { if (s_form != null) { s_form.Hide(); } } catch { }
            return;
        }
    }

    private static void Cleanup()
    {
        try
        {
            if (s_timer != null)
            {
                s_timer.Stop();
                s_timer.Dispose();
                s_timer = null;
            }
        }
        catch { }

        try
        {
            if (s_sessionHandler != null)
            {
                SystemEvents.SessionSwitch -= s_sessionHandler;
                s_sessionHandler = null;
            }
        }
        catch { }
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

        string tmp = s_path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        byte[] bytes = new UTF8Encoding(false).GetBytes(json);
        using (var fs = new FileStream(tmp, FileMode.Create, FileAccess.Write, FileShare.Read))
        {
            fs.Write(bytes, 0, bytes.Length);
            fs.Flush(true);
        }

        for (int attempt = 0; attempt < 5; attempt++)
        {
            try
            {
                if (File.Exists(s_path))
                {
                    File.Replace(tmp, s_path, null);
                }
                else
                {
                    File.Move(tmp, s_path);
                }
                return;
            }
            catch
            {
                try
                {
                    File.Copy(tmp, s_path, true);
                    try { File.Delete(tmp); } catch { }
                    return;
                }
                catch
                {
                    System.Threading.Thread.Sleep(50);
                }
            }
        }

        try { File.Delete(tmp); } catch { }
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

Write-WatcherLog ("LockSignalWatcher process start; pid={0}; target={1}; signal={2}; heartbeat={3}s" -f `
        $PID, $TargetUsername, $SignalPath, $HeartbeatSeconds)

# Restart the STA message loop if Task Scheduler / host tears it down without a hard kill.
$restartDelaySeconds = 5
while ($true) {
    try {
        Write-WatcherLog 'Entering LoginTimeLockSignalWatch.Run (Application.Run message pump).'
        [LoginTimeLockSignalWatch]::Run($SignalPath, $TargetUsername, ($HeartbeatSeconds * 1000))
        Write-WatcherLog 'Run returned (message pump ended); will restart.'
    }
    catch {
        $msg = 'Run ERROR: ' + $_.Exception.ToString()
        Write-WatcherLog $msg
        try { Add-Content -LiteralPath $watcherErrPath -Value ('{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg) -Encoding UTF8 } catch { }
    }

    Start-Sleep -Seconds $restartDelaySeconds
}
