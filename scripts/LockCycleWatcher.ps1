#Requires -Version 5.1
<#
.SYNOPSIS
  STA helper for Test-LockCycle.ps1. Writes SessionSwitch events to a TEMP file.
#>
param(
    [Parameter(Mandatory)][string]$EventFile,
    [Parameter(Mandatory)][int]$TimeoutSeconds
)

$ErrorActionPreference = 'Stop'

$dir = Split-Path -Parent $EventFile
if (-not (Test-Path -LiteralPath $dir)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
}

Add-Type -AssemblyName System.Windows.Forms

if (-not ('LockCycleFileWatch' -as [type])) {
    Add-Type -ReferencedAssemblies @('System.Windows.Forms') -Language CSharp -TypeDefinition @'
using System;
using System.IO;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

public static class LockCycleFileWatch
{
    public static void Run(string path, int timeoutMs)
    {
        File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [WATCHER] started" + Environment.NewLine);
        SessionSwitchEventHandler handler = (sender, e) =>
        {
            string line = DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [EVENT] " + e.Reason.ToString() + Environment.NewLine;
            File.AppendAllText(path, line);
        };
        SystemEvents.SessionSwitch += handler;
        try
        {
            int start = Environment.TickCount;
            while ((Environment.TickCount - start) < timeoutMs)
            {
                Application.DoEvents();
                Thread.Sleep(50);
            }
        }
        finally
        {
            SystemEvents.SessionSwitch -= handler;
            File.AppendAllText(path, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " [WATCHER] stopped" + Environment.NewLine);
        }
    }
}
'@
}

try {
    [LockCycleFileWatch]::Run($EventFile, ($TimeoutSeconds * 1000))
    exit 0
}
catch {
    $msg = '{0:yyyy-MM-dd HH:mm:ss} [WATCHER] ERROR {1}{2}' -f (Get-Date), $_.Exception.ToString(), [Environment]::NewLine
    try { Add-Content -LiteralPath $EventFile -Value $msg -Encoding UTF8 } catch { }
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
