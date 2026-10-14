# dsh-desk-card - render real card screenshots into assets/ (Windows dev helper).
#
# It starts one card process per payload exactly like the host half does, finds the
# resulting windows by process id + title, captures each one with PrintWindow (so the
# capture contains the card only - never your desktop), and composites them onto a
# neutral background at their real relative positions (which is what the stacked preset
# proves: the second card is laid out above the first one).
#
# Card text lives in tools/payloads/*.json (UTF-8) instead of in this file: Windows
# PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so this script stays pure ASCII and the
# payload files are decoded explicitly.
[CmdletBinding()]
param(
  [ValidateSet('approval-zh', 'done-zh', 'error-en', 'stacked-zh', 'all')][string]$Preset = 'all',
  [string]$OutDir = '',
  [double]$Scale = 1.2,
  [int]$HoldSeconds = 25
)

$ErrorActionPreference = 'Stop'

function Get-Here {
  $scriptPath = $MyInvocation.MyCommand.Path
  if ([string]::IsNullOrWhiteSpace($scriptPath) -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    return $PSScriptRoot
  }
  return [System.IO.Path]::GetDirectoryName($scriptPath)
}

$here = Get-Here
$packageRoot = [System.IO.Path]::GetDirectoryName($here)
if ([string]::IsNullOrWhiteSpace($OutDir)) { $OutDir = Join-Path $packageRoot 'assets' }
$payloadDir = Join-Path $here 'payloads'
$cardScript = Join-Path $packageRoot 'scripts\card.ps1'
if (-not (Test-Path -LiteralPath $cardScript)) { throw "card.ps1 not found at $cardScript" }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

Add-Type -AssemblyName System.Drawing

if (-not ('DshCapture' -as [type])) {
  Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;

public static class DshCapture
{
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }

    public delegate bool EnumProc(IntPtr hwnd, IntPtr param);

    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr param);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowTextW(IntPtr hwnd, StringBuilder text, int max);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hwnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr hwnd, IntPtr hdc, uint flags);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr SetThreadDpiAwarenessContext(IntPtr context);

    public static List<IntPtr> Windows(uint pid, string title)
    {
        List<IntPtr> found = new List<IntPtr>();
        EnumWindows(delegate(IntPtr hwnd, IntPtr param)
        {
            uint owner;
            GetWindowThreadProcessId(hwnd, out owner);
            if (owner != pid) return true;
            if (!IsWindowVisible(hwnd)) return true;
            StringBuilder sb = new StringBuilder(256);
            GetWindowTextW(hwnd, sb, 256);
            if (sb.ToString() == title) found.Add(hwnd);
            return true;
        }, IntPtr.Zero);
        return found;
    }
}
'@
}

# The card is DPI aware, this helper is not: without one of these calls GetWindowRect
# returns virtualized (scaled-down) sizes on a scaled display and PrintWindow then crops
# the right and bottom of the card. -4 = DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2.
try { $null = [DshCapture]::SetThreadDpiAwarenessContext([IntPtr](-4)) } catch { }
try { $null = [DshCapture]::SetProcessDPIAware() } catch { }

function Read-PayloadText {
  param([string]$Name)
  $path = Join-Path $payloadDir ($Name + '.json')
  if (-not (Test-Path -LiteralPath $path)) { throw "payload not found: $path" }
  return [System.IO.File]::ReadAllText($path, (New-Object System.Text.UTF8Encoding($false)))
}

function Start-CardProcess {
  param([string]$Json)
  $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Json))
  $argv = @(
    '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
    '-File', $cardScript,
    '-Payload', $payload,
    '-TimeoutSeconds', "$HoldSeconds",
    '-Scale', "$Scale",
    '-SkipWhenFullscreen', 'false',
    '-HostPid', "$PID",
    '-DebugLog', (Join-Path $env:TEMP 'dsh-desk-card-capture.log')
  )
  $quoted = ($argv | ForEach-Object { if ($_ -match '[\s"]') { '"' + ($_ -replace '"', '\"') + '"' } else { $_ } }) -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = 'powershell.exe'
  $psi.Arguments = $quoted
  $psi.UseShellExecute = $false
  $psi.CreateNoWindow = $true
  return [System.Diagnostics.Process]::Start($psi)
}

function Wait-CardWindow {
  param([int]$ProcessId, [int]$TimeoutSeconds = 20)
  $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    $handles = [DshCapture]::Windows([uint32]$ProcessId, 'DSH-CARD')
    if ($handles.Count -gt 0) { return $handles[0] }
    Start-Sleep -Milliseconds 150
  }
  throw "no DSH-CARD window appeared for pid $ProcessId"
}

function Save-WindowBitmap {
  param([IntPtr]$Handle, [string]$Path)
  $rect = New-Object DshCapture+RECT
  if (-not [DshCapture]::GetWindowRect($Handle, [ref]$rect)) { throw 'GetWindowRect failed' }
  $width = $rect.Right - $rect.Left
  $height = $rect.Bottom - $rect.Top
  if ($width -le 0 -or $height -le 0) { throw "bad window size ${width}x${height}" }

  $bmp = New-Object System.Drawing.Bitmap $width, $height
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $hdc = $gfx.GetHdc()
  # 2 = PW_RENDERFULLCONTENT, what DirectComposition/WPF windows need.
  $null = [DshCapture]::PrintWindow($Handle, $hdc, 2)
  $gfx.ReleaseHdc($hdc)
  $gfx.Dispose()
  $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
  $bmp.Dispose()

  return @{ Path = $Path; Left = $rect.Left; Top = $rect.Top; Width = $width; Height = $height }
}

$presets = @{
  'approval-zh' = @('approval-zh')
  'done-zh'     = @('done-zh')
  'error-en'    = @('error-en')
  'stacked-zh'  = @('approval-zh', 'done-zh')
}
# 'all' expands to the four output presets; every other value is one preset that maps to
# the card payloads above.
$targets = if ($Preset -eq 'all') { @('approval-zh', 'done-zh', 'error-en', 'stacked-zh') } else { @($Preset) }

$shots = @()
foreach ($presetName in $targets) {
  $group = @()
  foreach ($cardName in $presets[$presetName]) {
    $json = Read-PayloadText $cardName
    $proc = Start-CardProcess $json
    Write-Host "started $cardName card, pid=$($proc.Id)"
    $handle = Wait-CardWindow -ProcessId $proc.Id
    Start-Sleep -Milliseconds 800
    $shot = Save-WindowBitmap -Handle $handle -Path (Join-Path $env:TEMP ('card-' + $cardName + '.png'))
    Write-Host ("  captured {0} -> {1}x{2} at {3},{4}" -f $cardName, $shot.Width, $shot.Height, $shot.Left, $shot.Top)
    $group += [pscustomobject]@{ Name = $cardName; Proc = $proc; Shot = $shot }
  }
  $shots += $group

  # Composite this preset alone and close its cards immediately: a card that stays open
  # would push the next preset's card into the stack and ruin the layout being captured.
  $left = ($group | ForEach-Object { [int]$_.Shot.Left } | Measure-Object -Minimum).Minimum
  $top = ($group | ForEach-Object { [int]$_.Shot.Top } | Measure-Object -Minimum).Minimum
  $right = ($group | ForEach-Object { [int]$_.Shot.Left + [int]$_.Shot.Width } | Measure-Object -Maximum).Maximum
  $bottom = ($group | ForEach-Object { [int]$_.Shot.Top + [int]$_.Shot.Height } | Measure-Object -Maximum).Maximum
  $padding = 14
  $width = [int]$right - [int]$left + 2 * $padding
  $height = [int]$bottom - [int]$top + 2 * $padding
  Write-Host "  canvas ${width}x${height} (union ${left},${top}..${right},${bottom})"
  if ($width -le 0 -or $height -le 0) { throw "bad canvas ${width}x${height}" }
  $canvas = New-Object System.Drawing.Bitmap $width, $height
  $gfx = [System.Drawing.Graphics]::FromImage($canvas)
  $gfx.Clear([System.Drawing.Color]::FromArgb(255, 15, 16, 21))
  foreach ($item in $group) {
    $img = [System.Drawing.Image]::FromFile($item.Shot.Path)
    $gfx.DrawImage($img, ($item.Shot.Left - $left + $padding), ($item.Shot.Top - $top + $padding), $item.Shot.Width, $item.Shot.Height)
    $img.Dispose()
  }
  $gfx.Dispose()
  $target = Join-Path $OutDir ($presetName + '.png')
  $canvas.Save($target, [System.Drawing.Imaging.ImageFormat]::Png)
  $canvas.Dispose()
  Write-Host "wrote $target"

  foreach ($item in $group) {
    try { if (-not $item.Proc.HasExited) { $item.Proc.Kill() } } catch { }
  }
  Start-Sleep -Milliseconds 400
}

Write-Host 'done'
exit 0
