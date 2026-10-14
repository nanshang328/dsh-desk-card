param(
  [string]$Payload = "",
  # 0 = never auto-close (the card waits for a click).
  [int]$TimeoutSeconds = 0,
  # strings, not [bool]: with -File, "true"/"false" arrive as strings and [bool] throws.
  [string]$SkipWhenFullscreen = "true",
  [double]$Scale = 1.2,
  # Host PID: the card closes itself if the host restarts (no orphan windows).
  [int]$HostPid = 0,
  [string]$DebugLog = ""
)

# ASCII-only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so any
# non-ASCII literal here would be mojibake and can even break parsing. Every visible
# string arrives through -Payload as base64(UTF-8 JSON).

$ErrorActionPreference = "Stop"

function Write-Trace([string]$message) {
  if ($DebugLog -eq "") { return }
  try { Add-Content -LiteralPath $DebugLog -Value ((Get-Date -Format "HH:mm:ss.fff") + " " + $message) -Encoding UTF8 } catch { }
}

Write-Trace "start len=$($Payload.Length) timeout=$TimeoutSeconds skip=$SkipWhenFullscreen"

# ---------- payload ----------
$d = $null
try {
  $d = ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Payload))) | ConvertFrom-Json
} catch {
  Write-Trace "decode FAILED: $($_.Exception.Message)"
  exit 2
}
if ($null -eq $d) { exit 2 }

$badge = [string]$d.badge
$head = [string]$d.head
$body = [string]$d.body
$footer = [string]$d.footer
$okLabel = [string]$d.okLabel
$hostProcess = [string]$d.hostProcess
$okCode = 10
if ($null -ne $d.okCode) { try { $okCode = [int]$d.okCode } catch { $okCode = 10 } }
if ([string]::IsNullOrWhiteSpace($head)) { $head = "DSH" }
if ([string]::IsNullOrWhiteSpace($hostProcess)) { $hostProcess = "DeepSeek Harness" }

# Exit protocol read by the host plugin:
#   0  gate skipped            -> host falls back to its own prompt
#   10 primary button          -> host grants 'allowed-once'
#   12 card body clicked       -> host hands the decision to the DSH UI (after focusing it)
#   20 primary button on a restart card -> host restarts
#   3  render failed           -> host falls back as well
$script:exitCode = 0

# ---------- native helpers ----------
if (-not ("DshCardNative" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class DshCardNative
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern int GetWindowTextW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr p);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLengthW(IntPtr h);
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);

    public delegate bool EnumWindowsProc(IntPtr hWnd, IntPtr lParam);

    public static string ActivateProcessWindow(string processName)
    {
        IntPtr found = IntPtr.Zero;
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h)) return true;
            if (GetWindowTextLengthW(h) == 0) return true;
            uint pid;
            GetWindowThreadProcessId(h, out pid);
            try
            {
                System.Diagnostics.Process proc = System.Diagnostics.Process.GetProcessById((int)pid);
                if (string.Equals(proc.ProcessName, processName, StringComparison.OrdinalIgnoreCase))
                {
                    found = h;
                    return false;
                }
            }
            catch { }
            return true;
        }, IntPtr.Zero);
        if (found == IntPtr.Zero) return "not-found";
        if (IsIconic(found)) ShowWindow(found, 9);
        return SetForegroundWindow(found) ? "ok" : "foreground-refused";
    }

    // Rects of the sibling cards already on screen, as "l,t,r,b;l,t,r,b" (physical px).
    public static string SiblingRects(string title)
    {
        StringBuilder all = new StringBuilder();
        EnumWindows(delegate(IntPtr h, IntPtr p)
        {
            if (!IsWindowVisible(h)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(h, sb, 256);
            if (!string.Equals(sb.ToString(), title, StringComparison.Ordinal)) return true;
            RECT r;
            if (!GetWindowRect(h, out r)) return true;
            if (all.Length > 0) all.Append(';');
            all.Append(r.Left).Append(',').Append(r.Top).Append(',').Append(r.Right).Append(',').Append(r.Bottom);
            return true;
        }, IntPtr.Zero);
        return all.ToString();
    }
}
'@
}
try { $null = [DshCardNative]::SetProcessDPIAware() } catch { }
Write-Trace "native ok"

# ---------- gate: fullscreen / do not disturb ----------
$quns = 0
$null = [DshCardNative]::SHQueryUserNotificationState([ref]$quns)
# 3 = D3D fullscreen, 4 = presentation, 6 = quiet hours / do-not-disturb
if ($quns -eq 3 -or $quns -eq 4 -or $quns -eq 6) { Write-Trace "skip quns=$quns"; exit 0 }

if ($SkipWhenFullscreen -eq "true") {
  $fg = [DshCardNative]::GetForegroundWindow()
  if ($fg -ne [IntPtr]::Zero) {
    $sb = New-Object System.Text.StringBuilder 256
    $null = [DshCardNative]::GetClassNameW($fg, $sb, 256)
    $cls = $sb.ToString()
    $fgPid = 0
    $null = [DshCardNative]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    $pname = ""
    try { $pname = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { }
    Write-Trace "fg class=[$cls] proc=[$pname]"
    if ((@("Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd") -notcontains $cls) -and
        (@("TextInputHost", "explorer") -notcontains $pname)) {
      $r = New-Object DshCardNative+RECT
      if ([DshCardNative]::GetWindowRect($fg, [ref]$r)) {
        $mon = [DshCardNative]::MonitorFromWindow($fg, 2)
        $mi = New-Object DshCardNative+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ([DshCardNative]::GetMonitorInfoW($mon, [ref]$mi)) {
          $covers = ($r.Left -le $mi.rcMonitor.Left) -and ($r.Top -le $mi.rcMonitor.Top) -and
                    ($r.Right -ge $mi.rcMonitor.Right) -and ($r.Bottom -ge $mi.rcMonitor.Bottom)
          if ($covers) { Write-Trace "skip fullscreen ($($r.Right - $r.Left)x$($r.Bottom - $r.Top))"; exit 0 }
        }
      }
    }
  }
}
Write-Trace "gate passed"

$windowTitle = "DSH-CARD"
$stackRaw = ""
$siblingCount = 0
try { $stackRaw = [DshCardNative]::SiblingRects($windowTitle) } catch { }
if (-not [string]::IsNullOrEmpty($stackRaw)) { $siblingCount = ($stackRaw -split ';').Count }
Write-Trace "siblings=$siblingCount"
$stackRaw = $stackRaw

# ---------- render ----------
try {
  Add-Type -AssemblyName PresentationFramework
  Add-Type -AssemblyName PresentationCore
  Add-Type -AssemblyName WindowsBase

  $w = 380 * $Scale
  $fsBadge = 11 * $Scale
  $fsHead = 15 * $Scale
  $fsBody = 12 * $Scale
  $fsFooter = 10 * $Scale
  $fsButton = 11 * $Scale
  $padH = 16 * $Scale
  $padV = 14 * $Scale
  $gapSm = 6 * $Scale
  $gapMd = 8 * $Scale
  $gapLg = 10 * $Scale
  $radius = 12 * $Scale
  $margin = 18
  if ([string]::IsNullOrWhiteSpace($okLabel)) { $okLabel = "OK" }

  function New-Brush([int]$a, [int]$r, [int]$g, [int]$b) {
    return New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromArgb($a, $r, $g, $b))
  }

  $win = New-Object System.Windows.Window
  $win.WindowStyle = [System.Windows.WindowStyle]::None
  $win.AllowsTransparency = $true
  $win.Background = [System.Windows.Media.Brushes]::Transparent
  $win.Topmost = $true
  $win.ShowInTaskbar = $false
  $win.ShowActivated = $false
  $win.ResizeMode = [System.Windows.ResizeMode]::NoResize
  $win.SizeToContent = [System.Windows.SizeToContent]::Height
  $win.Width = $w
  $win.Title = $windowTitle

  $border = New-Object System.Windows.Controls.Border
  $border.CornerRadius = New-Object System.Windows.CornerRadius($radius)
  $border.Background = New-Brush 246 22 24 30
  $border.BorderThickness = New-Object System.Windows.Thickness(1)
  $border.BorderBrush = New-Brush 255 92 132 255
  $border.Padding = New-Object System.Windows.Thickness($padH, $padV, $padH, $padV)

  $sp = New-Object System.Windows.Controls.StackPanel
  $tbBadge = New-Object System.Windows.Controls.TextBlock
  $tbBadge.Text = $badge
  $tbBadge.FontSize = $fsBadge
  $tbBadge.FontWeight = [System.Windows.FontWeights]::SemiBold
  $tbBadge.Foreground = New-Brush 255 130 165 255

  $tbHead = New-Object System.Windows.Controls.TextBlock
  $tbHead.Text = $head
  $tbHead.FontSize = $fsHead
  $tbHead.FontWeight = [System.Windows.FontWeights]::Bold
  $tbHead.Foreground = New-Brush 255 245 246 250
  $tbHead.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tbHead.Margin = New-Object System.Windows.Thickness(0, $gapSm, 0, 0)

  $tbBody = New-Object System.Windows.Controls.TextBlock
  $tbBody.Text = $body
  $tbBody.FontSize = $fsBody
  $tbBody.Foreground = New-Brush 255 178 182 196
  $tbBody.TextWrapping = [System.Windows.TextWrapping]::Wrap
  $tbBody.Margin = New-Object System.Windows.Thickness(0, $gapMd, 0, 0)

  $tbFooter = New-Object System.Windows.Controls.TextBlock
  $tbFooter.Text = $footer
  $tbFooter.FontSize = $fsFooter
  $tbFooter.Foreground = New-Brush 255 120 124 138
  $tbFooter.Margin = New-Object System.Windows.Thickness(0, $gapLg, 0, 0)

  $btn = New-Object System.Windows.Controls.Button
  $btn.Content = $okLabel
  $btn.FontSize = $fsButton
  # NOTE: in PowerShell the comma binds tighter than '*', so every computed argument
  # needs its own parentheses: (15 * $Scale, 5 * $Scale) would parse as 15 * (array).
  $btn.Padding = New-Object System.Windows.Thickness((15 * $Scale), (5 * $Scale), (15 * $Scale), (5 * $Scale))
  $btn.Margin = New-Object System.Windows.Thickness(0, $gapMd, 0, 0)
  $btn.HorizontalAlignment = [System.Windows.HorizontalAlignment]::Right
  $btn.Background = New-Brush 255 58 92 205
  $btn.Foreground = New-Brush 255 255 255 255
  $btn.BorderThickness = New-Object System.Windows.Thickness(0)
  $btn.Cursor = [System.Windows.Input.Cursors]::Hand
  $btn.Add_Click({
    Write-Trace "primary button -> exit $okCode"
    $script:exitCode = $okCode
    try { $win.Close() } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
  })

  $null = $sp.Children.Add($tbBadge)
  $null = $sp.Children.Add($tbHead)
  $null = $sp.Children.Add($tbBody)
  $null = $sp.Children.Add($tbFooter)
  $null = $sp.Children.Add($btn)
  $border.Child = $sp
  $win.Content = $border

  $border.Add_MouseLeftButtonUp({
    Write-Trace "body click -> inspect"
    try { Write-Trace ("activate=" + [DshCardNative]::ActivateProcessWindow($hostProcess)) } catch { }
    $script:exitCode = 12
    try { $win.Close() } catch { }
    try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
  })

  $win.Add_ContentRendered({
    try {
      $wa = [System.Windows.SystemParameters]::WorkArea
      $dipScale = 1.0
      try {
        $primary = [DshCardNative]::MonitorFromWindow([IntPtr]::Zero, 1)
        $mi = New-Object DshCardNative+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ([DshCardNative]::GetMonitorInfoW($primary, [ref]$mi)) {
          $physW = $mi.rcWork.Right - $mi.rcWork.Left
          if ($wa.Width -gt 0 -and $physW -gt 0) { $dipScale = $physW / $wa.Width }
        }
      } catch { }

      $top = $wa.Bottom - $win.ActualHeight - $margin
      if (-not [string]::IsNullOrEmpty($stackRaw) -and $dipScale -gt 0) {
        $others = @()
        foreach ($part in ($stackRaw -split ';')) {
          $nums = $part -split ','
          if ($nums.Count -eq 4) {
            $others += [pscustomobject]@{ Top = [double]$nums[1] / $dipScale; Bottom = [double]$nums[3] / $dipScale }
          }
        }
        for ($guard = 0; $guard -lt 10; $guard++) {
          $moved = $false
          foreach ($other in $others) {
            if (($top -lt $other.Bottom) -and (($top + $win.ActualHeight) -gt $other.Top)) {
              $top = $other.Top - $win.ActualHeight - (8 * $Scale)
              $moved = $true
            }
          }
          if (-not $moved) { break }
        }
      }
      $win.Left = $wa.Right - $win.ActualWidth - $margin
      if ($top -lt ($wa.Top + 8)) { $top = $wa.Top + 8 }
      $win.Top = $top
      Write-Trace ("placed " + [int]$win.Left + "," + [int]$win.Top + " size " + [int]$win.ActualWidth + "x" + [int]$win.ActualHeight)
    } catch { Write-Trace "place failed: $($_.Exception.Message)" }
  })

  if ($TimeoutSeconds -gt 0) {
    $script:timer = New-Object System.Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromSeconds($TimeoutSeconds)
    $script:timer.Add_Tick({
      $script:timer.Stop()
      try { $win.Close() } catch { }
      try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
    })
    $script:timer.Start()
  }

  if ($HostPid -gt 0) {
    $script:watchdog = New-Object System.Windows.Threading.DispatcherTimer
    $script:watchdog.Interval = [TimeSpan]::FromSeconds(3)
    $script:watchdog.Add_Tick({
      $alive = $false
      try { $null = Get-Process -Id $HostPid -ErrorAction Stop; $alive = $true } catch { }
      if (-not $alive) {
        Write-Trace "host $HostPid gone -> closing"
        try { $script:watchdog.Stop() } catch { }
        try { $win.Close() } catch { }
        try { [System.Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() } catch { }
      }
    })
    $script:watchdog.Start()
  }

  $null = $win.Show()
  Write-Trace "shown"
  [System.Windows.Threading.Dispatcher]::Run()
  Write-Trace "exiting code=$script:exitCode"
  [System.Environment]::Exit($script:exitCode)
} catch {
  Write-Trace "RENDER FAILED: $($_.Exception.Message)"
  exit 3
}
