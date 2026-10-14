param(
  [int]$HoldSeconds = 8,
  # 0 = primary monitor only (default); 1 = all monitors spanned.
  [int]$SpanAll = 0
)

# Test harness only: paints an opaque borderless window covering the screen so the
# card gate has something to trip on. ASCII-only (5.1 reads BOM-less .ps1 as ANSI).

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

$left = 0.0
$top = 0.0
$width = [double][System.Windows.SystemParameters]::PrimaryScreenWidth
$height = [double][System.Windows.SystemParameters]::PrimaryScreenHeight

if ($SpanAll -eq 1) {
  $left = [double][System.Windows.SystemParameters]::VirtualScreenLeft
  $top = [double][System.Windows.SystemParameters]::VirtualScreenTop
  $width = [double][System.Windows.SystemParameters]::VirtualScreenWidth
  $height = [double][System.Windows.SystemParameters]::VirtualScreenHeight
}

$w = New-Object System.Windows.Window
$w.WindowStyle = [System.Windows.WindowStyle]::None
$w.ResizeMode = [System.Windows.ResizeMode]::NoResize
$w.ShowInTaskbar = $false
$w.Topmost = $true
$w.Left = $left
$w.Top = $top
$w.Width = $width
$w.Height = $height
$w.Background = New-Object System.Windows.Media.SolidColorBrush ([System.Windows.Media.Color]::FromRgb(18, 18, 22))
$w.Title = "DSH-FAKE-FULLSCREEN"

$timer = New-Object System.Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromSeconds($HoldSeconds)
$timer.Add_Tick({
  $timer.Stop()
  $w.Close()
})

$w.Add_SourceInitialized({
  $w.Activate() | Out-Null
  $timer.Start()
})

$null = $w.ShowDialog()
exit 0