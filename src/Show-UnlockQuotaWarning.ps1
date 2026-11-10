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

# Elapsed unlocked time as H:MM (e.g. 30 -> 0:30, 90 -> 1:30).
$elapsedHours = [int][Math]::Floor($Minutes / 60)
$elapsedMins = [int]($Minutes % 60)
$elapsedHm = '{0}:{1:D2}' -f $elapsedHours, $elapsedMins

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
$form.ClientSize = New-Object System.Drawing.Size(560, 300)
$form.KeyPreview = $true
# Swallow keys so the dialog stays modal/blocking for the countdown.
$form.Add_KeyDown({ $_.SuppressKeyPress = $true })

# Layout (top -> bottom):
#   1) "Unlocked time so far:"
#   2) current unlocked time (H:MM)
#   3) "Twoje OCZY muszą ODPOCZĄĆ !"
#   4) countdown footer (same place as before)

$title = New-Object System.Windows.Forms.Label
$title.AutoSize = $false
$title.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$title.Dock = [System.Windows.Forms.DockStyle]::Top
$title.Height = 48
$title.Font = New-Object System.Drawing.Font('Segoe UI', 12, [System.Drawing.FontStyle]::Regular)
$title.Text = 'Unlocked time so far:'
$title.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$title.Padding = New-Object System.Windows.Forms.Padding(12, 12, 12, 0)

# Large display: elapsed unlocked time as hours:minutes.
$elapsedLabel = New-Object System.Windows.Forms.Label
$elapsedLabel.AutoSize = $false
$elapsedLabel.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$elapsedLabel.Dock = [System.Windows.Forms.DockStyle]::Fill
$elapsedLabel.Font = New-Object System.Drawing.Font('Segoe UI', 36, [System.Drawing.FontStyle]::Bold)
$elapsedLabel.ForeColor = [System.Drawing.Color]::FromArgb(255, 196, 0)
$elapsedLabel.Text = $elapsedHm

$restMessage = New-Object System.Windows.Forms.Label
$restMessage.AutoSize = $false
$restMessage.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$restMessage.Dock = [System.Windows.Forms.DockStyle]::Bottom
$restMessage.Height = 56
$restMessage.Font = New-Object System.Drawing.Font('Segoe UI', 18, [System.Drawing.FontStyle]::Bold)
# Build with [char] code points so Windows PowerShell 5.1 (-File, no BOM)
# does not mis-decode UTF-8 Polish letters as the system ANSI code page.
$restMessage.Text = ('Twoje OCZY musz{0} ODPOCZ{1}{2} !' -f `
        [char]0x0105, [char]0x0104, [char]0x0106)  # ą Ą Ć
$restMessage.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 80)
$restMessage.Padding = New-Object System.Windows.Forms.Padding(12, 4, 12, 0)

$footer = New-Object System.Windows.Forms.Label
$footer.AutoSize = $false
$footer.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$footer.Dock = [System.Windows.Forms.DockStyle]::Bottom
$footer.Height = 40
$footer.Font = New-Object System.Drawing.Font('Segoe UI', 10)
$footer.ForeColor = [System.Drawing.Color]::FromArgb(200, 200, 200)
$footer.Text = ('Screen will lock in {0} s...' -f $CountdownSeconds)

# Dock order: Fill first; first Bottom = outermost edge (countdown);
# second Bottom stacks above it (Polish); Top last.
$form.Controls.Add($elapsedLabel)
$form.Controls.Add($footer)
$form.Controls.Add($restMessage)
$form.Controls.Add($title)

$script:remaining = [int]$CountdownSeconds
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
        $script:remaining--
        if ($script:remaining -gt 0) {
            $footer.Text = ('Screen will lock in {0} s...' -f $script:remaining)
            return
        }
        $timer.Stop()
        $footer.Text = 'Screen will lock now...'
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
