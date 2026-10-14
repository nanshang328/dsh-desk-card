param(
  [int]$MaxSeconds = 25,
  [string]$OutFile = "",
  [int]$PollMs = 500,
  # When true, stop at the first release (the card-gate contract).
  [string]$StopOnRelease = "false"
)

# Test harness only: re-implements card.ps1's gate predicate verbatim so we can watch
# it flip blocked -> released against a controlled fullscreen window.
# ASCII-only (5.1 reads BOM-less .ps1 as ANSI).

$ErrorActionPreference = "Stop"

if (-not ("DshGateProbe" -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

public static class DshGateProbe
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }

    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
    [DllImport("user32.dll")] public static extern bool GetMonitorInfoW(IntPtr mon, ref MONITORINFO mi);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetClassNameW(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("shell32.dll")] public static extern int SHQueryUserNotificationState(out int state);
}
'@
}

function Get-GateState {
  $quns = 0
  $null = [DshGateProbe]::SHQueryUserNotificationState([ref]$quns)

  $cls = ""
  $pname = ""
  $covers = $false
  $rect = ""
  $fg = [DshGateProbe]::GetForegroundWindow()

  if ($fg -ne [IntPtr]::Zero) {
    $sb = New-Object System.Text.StringBuilder 256
    $null = [DshGateProbe]::GetClassNameW($fg, $sb, 256)
    $cls = $sb.ToString()
    $fgPid = 0
    $null = [DshGateProbe]::GetWindowThreadProcessId($fg, [ref]$fgPid)
    try { $pname = (Get-Process -Id $fgPid -ErrorAction Stop).ProcessName } catch { }

    if ((@("Progman", "WorkerW", "Shell_TrayWnd", "Shell_SecondaryTrayWnd") -notcontains $cls) -and
        (@("TextInputHost", "explorer") -notcontains $pname)) {
      $r = New-Object DshGateProbe+RECT
      if ([DshGateProbe]::GetWindowRect($fg, [ref]$r)) {
        $rect = "$($r.Left),$($r.Top),$($r.Right),$($r.Bottom)"
        $mon = [DshGateProbe]::MonitorFromWindow($fg, 2)
        $mi = New-Object DshGateProbe+MONITORINFO
        $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
        if ([DshGateProbe]::GetMonitorInfoW($mon, [ref]$mi)) {
          $covers = ($r.Left -le $mi.rcMonitor.Left) -and ($r.Top -le $mi.rcMonitor.Top) -and
                    ($r.Right -ge $mi.rcMonitor.Right) -and ($r.Bottom -ge $mi.rcMonitor.Bottom)
        }
      }
    }
  }

  $blockedByQuns = ($quns -eq 3 -or $quns -eq 4 -or $quns -eq 6)
  $blocked = $blockedByQuns -or $covers

  [pscustomobject]@{
    Quns       = $quns
    Class      = $cls
    Process    = $pname
    Rect       = $rect
    Covers     = $covers
    Blocked    = $blocked
    Reason     = if ($blockedByQuns) { "quns=$quns" } elseif ($covers) { "fullscreen-window" } else { "free" }
  }
}

$started = Get-Date
$deadline = $started.AddSeconds($MaxSeconds)
$lines = New-Object System.Collections.Generic.List[string]
$previous = ""

while ((Get-Date) -lt $deadline) {
  $state = Get-GateState
  $stamp = ((Get-Date) - $started).TotalSeconds.ToString("0.0")
  $line = "$stamp`t$($state.Reason)`tquns=$($state.Quns)`tproc=$($state.Process)`tclass=$($state.Class)`trect=$($state.Rect)"

  if ($state.Reason -ne $previous) {
    $lines.Add("TRANSITION`t$line")
    $previous = $state.Reason
  } else {
    $lines.Add("stable    `t$line")
  }

  if ($StopOnRelease -eq "true" -and $previous -ne "free" -and $state.Reason -eq "free") {
    break
  }

  Start-Sleep -Milliseconds $PollMs
}

if ($OutFile -ne "") {
  $lines | Set-Content -LiteralPath $OutFile -Encoding UTF8
} else {
  $lines
}
exit 0