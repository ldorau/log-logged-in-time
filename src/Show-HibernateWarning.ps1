#Requires -Version 5.1
<#
.SYNOPSIS
  Warning dialog: hibernate after remaining unlocked time (MM:SS).
.DESCRIPTION
  Runs in the target user's session. Shows a top-most message with an OK
  button that dismisses the window. Does not hibernate itself.
  -RemainingSeconds is the cumulative unlocked time left until hibernate.
#>
[CmdletBinding()]
param(
    [double]$RemainingSeconds = 300,
    [string]$DebugLogPath = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Write-HibernateWarnDebug {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0:yyyy-MM-dd HH:mm:ss.fff} [DEBUG] [Show-HibernateWarning] {1}' -f (Get-Date), $Message
    try { [Console]::Error.WriteLine($line) } catch { }
    if ([string]::IsNullOrWhiteSpace($DebugLogPath)) { return }
    try {
        $dir = Split-Path -Parent $DebugLogPath
        if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        Add-Content -LiteralPath $DebugLogPath -Value $line -Encoding UTF8
    }
    catch { }
}

Write-HibernateWarnDebug (
    "start; User={0}; SessionId={1}" -f $env:USERNAME, $env:SESSIONNAME)

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    Add-Type -Namespace User32HibWarn -Name Native -MemberDefinition @"
[System.Runtime.InteropServices.DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);
"@ -ErrorAction SilentlyContinue
}
catch {
    Write-HibernateWarnDebug ("Add-Type FAILED: {0}" -f $_.Exception.Message)
    exit 2
}

$remain = [Math]::Max(0.0, [double]$RemainingSeconds)
$mm = [int][Math]::Floor($remain / 60.0)
$ss = [int][Math]::Floor($remain % 60.0)
$mmSs = '{0:D2}:{1:D2}' -f $mm, $ss
$messageText = ('UWAGA: za {0} minut:sekund komputer zostanie zahibernowany !!!' -f $mmSs)
Write-HibernateWarnDebug ("message; RemainingSeconds={0}; display={1}" -f $remain, $mmSs)

$form = New-Object System.Windows.Forms.Form
$form.Text = 'LoginTimeLogger'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::CenterScreen
$form.MaximizeBox = $false
$form.MinimizeBox = $false
$form.ControlBox = $true
$form.TopMost = $true
$form.ShowInTaskbar = $true
$form.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
$form.ForeColor = [System.Drawing.Color]::White
$form.ClientSize = New-Object System.Drawing.Size(640, 220)
$form.AcceptButton = $null

$label = New-Object System.Windows.Forms.Label
$label.AutoSize = $false
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$label.Dock = [System.Windows.Forms.DockStyle]::Fill
$label.Font = New-Object System.Drawing.Font('Segoe UI', 14, [System.Drawing.FontStyle]::Bold)
$label.ForeColor = [System.Drawing.Color]::FromArgb(255, 220, 80)
$label.Text = $messageText
$label.Padding = New-Object System.Windows.Forms.Padding(16, 16, 16, 8)

$ok = New-Object System.Windows.Forms.Button
$ok.Text = 'OK'
$ok.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$ok.Width = 120
$ok.Height = 36
$ok.Anchor = [System.Windows.Forms.AnchorStyles]::Bottom
$ok.DialogResult = [System.Windows.Forms.DialogResult]::OK
$ok.BackColor = [System.Drawing.Color]::FromArgb(60, 60, 68)
$ok.ForeColor = [System.Drawing.Color]::White
$ok.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat

$buttonPanel = New-Object System.Windows.Forms.Panel
$buttonPanel.Dock = [System.Windows.Forms.DockStyle]::Bottom
$buttonPanel.Height = 56
$buttonPanel.BackColor = [System.Drawing.Color]::FromArgb(32, 32, 36)
$buttonPanel.Controls.Add($ok)
$form.Controls.Add($label)
$form.Controls.Add($buttonPanel)
$form.AcceptButton = $ok

$form.Add_Shown({
        $ok.Left = [int](($buttonPanel.ClientSize.Width - $ok.Width) / 2)
        $ok.Top = [int](($buttonPanel.ClientSize.Height - $ok.Height) / 2)
        Write-HibernateWarnDebug ("form Shown; Handle={0}" -f $form.Handle)
        try { [void][User32HibWarn.Native]::SetForegroundWindow($form.Handle) } catch { }
        $ok.Focus()
    })

Write-HibernateWarnDebug 'ShowDialog begin'
[void]$form.ShowDialog()
Write-HibernateWarnDebug 'ShowDialog end; exit 0'
exit 0
