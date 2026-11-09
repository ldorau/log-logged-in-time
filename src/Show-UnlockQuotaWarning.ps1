#Requires -Version 5.1
<#
.SYNOPSIS
  Blocking countdown on the interactive desktop, then LockWorkStation.
.DESCRIPTION
  Intended to run inside the target user's session (CreateProcessAsUser from SYSTEM).
  Shows a top-most modal for -CountdownSeconds, then locks the workstation.
  Exits 0 only when LockWorkStation (or rundll32 fallback) reports success.
#>
[CmdletBinding()]
param(
    [int]$Minutes = 30,
    [int]$CountdownSeconds = 3
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($Minutes -lt 1) { $Minutes = 30 }
if ($CountdownSeconds -lt 1) { $CountdownSeconds = 3 }
if ($CountdownSeconds -gt 60) { $CountdownSeconds = 60 }

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace User32 -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError=true)]
public static extern bool LockWorkStation();
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
"@ -ErrorAction SilentlyContinue

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LoginTimeLogger'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ControlBox = $false
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
$form.ForeColor = [System.Drawing.Color]::White
$form.ClientSize = New-Object System.Drawing.Size(520, 220)
$form.KeyPreview = $true
# Swallow keys so the dialog stays modal/blocking for the countdown.
$form.Add_KeyDown({ $_.SuppressKeyPress = $true })

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$title.Dock = [System.Windows.Forms.DockStyle]::Top
$title.Height = 70
$title.Font = New-Object System.Drawing.Font('Segoe UI', 16, [System.Drawing.FontStyle]::Bold)
$title.Text = ("{0} minutes of unlocked time have passed." -f $Minutes)
$title.ForeColor = [System.Drawing.Color]::White
$title.Padding = New-Object System.Windows.Forms.Padding(12, 16, 12, 0)

$countdown = New-Object System.Windows.Forms.Label
$countdown.AutoSize = $false
$countdown.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$countdown.Dock = [System.Windows.Forms.DockStyle]::Fill
$countdown.Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
$countdown.ForeColor = [System.Drawing.Color]::FromArgb(255, 196, 0)
$countdown.Text = "$CountdownSeconds"

$footer = New-Object System.Windows.Forms.Label
$footer.AutoSize = $false
$footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
$footer.Height = 40
$footer.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$footer.Text = 'Screen will lock when the timer reaches zero.'

$form.Controls.Add($countdown)
$form.Controls.Add($footer)
$form.Controls.Add($title)

$script:remaining = [int]$CountdownSeconds
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
        $script:remaining--
        if ($script:remaining -gt 0) {
            $countdown.Text = "$script:remaining"
            return
        }
        $timer.Stop()
        $countdown.Text = '0'
        $form.Close()
    })

$form.Add_Shown({
        try { [void][User32.Native]::SetForegroundWindow($form.Handle) } catch { }
        $timer.Start()
    })

$form.Add_FormClosed({
        if ($timer) { $timer.Stop(); $timer.Dispose() }
    })

[void]$form.ShowDialog()

# Brief pause so the dialog fully tears down before locking.
Start-Sleep -Milliseconds 250

$lockOk = $false
$lockDetail = ''
try {
    $lockOk = [User32.Native]::LockWorkStation()
    if (-not $lockOk) {
        $lockDetail = ('LockWorkStation returned false; Win32Error={0}' -f `
                [System.Runtime.InteropServices.Marshal]::GetLastWin32Error())
    }
}
catch {
    $lockDetail = ('LockWorkStation threw: {0}' -f $_.Exception.Message)
}

if (-not $lockOk) {
    try {
        $rundll = Join-Path $env:SystemRoot 'System32\rundll32.exe'
        $p = Start-Process -FilePath $rundll -ArgumentList @('user32.dll,LockWorkStation') `
            -Wait -PassThru -WindowStyle Hidden
        if ($null -ne $p -and [int]$p.ExitCode -eq 0) {
            $lockOk = $true
            $lockDetail = 'rundll32 user32.dll,LockWorkStation fallback used'
        }
        else {
            $exit = if ($null -ne $p) { $p.ExitCode } else { '(null)' }
            $lockDetail = ("{0}; rundll32 exit={1}" -f $lockDetail, $exit)
        }
    }
    catch {
        $lockDetail = ("{0}; rundll32 failed: {1}" -f $lockDetail, $_.Exception.Message)
    }
}

if (-not $lockOk) {
    [Console]::Error.WriteLine(("Unlock-quota lock failed: {0}" -f $lockDetail))
    exit 1
}

exit 0
