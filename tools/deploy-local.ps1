# dsh-desk-card - install this working copy into a DSH profile (Windows dev helper).
#
# It mirrors exactly what `dsh plugin add <dir>` does, so the plugin ends up mounted
# through the normal bundle mechanism instead of a hand-written absolute-path row:
#   1) copy this package into <dsh-home>\profiles\<profile>\plugins\<package name>
#   2) run `dsh plugin --profile <profile> add <that directory>` (appends the package to
#      dsh.profile.bundles and records it as a link: dependency)
#
# Restarting DSH afterwards is deliberately left to you: this script never kills the app.
#
# ASCII only on purpose: Windows PowerShell 5.1 reads a BOM-less .ps1 as ANSI, and a
# mangled multi-byte character has previously broken this project's parser.
[CmdletBinding()]
param(
  [string]$Profile = 'desktop',
  [string]$DshHome = (Join-Path $env:USERPROFILE '.dsh'),
  [string]$DshCmd = (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness\resources\runtime\cli\bin\dsh.cmd'),
  [string]$Source = ''
)

$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($Source)) {
  # Not a param default: Windows PowerShell 5.1 can evaluate defaults before
  # $PSCommandPath exists, and GetDirectoryName('') throws "not of a legal form".
  $scriptPath = $MyInvocation.MyCommand.Path
  if ([string]::IsNullOrWhiteSpace($scriptPath) -and -not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $scriptPath = Join-Path $PSScriptRoot 'deploy-local.ps1'
  }
  $Source = [System.IO.Path]::GetDirectoryName([System.IO.Path]::GetDirectoryName($scriptPath))
}
if ([string]::IsNullOrWhiteSpace($Source)) { throw 'cannot determine the package directory; pass -Source <path>' }

$manifest = Join-Path $Source 'package.json'
if (-not (Test-Path -LiteralPath $manifest)) { throw "package.json not found in $Source" }
$pkg = (Get-Content -LiteralPath $manifest -Raw) | ConvertFrom-Json
$name = $pkg.name
if (-not $name) { throw "package.json has no name" }

$profileDir = Join-Path $DshHome ("profiles\" + $Profile)
if (-not (Test-Path -LiteralPath $profileDir)) { throw "profile not found: $profileDir" }

$dest = Join-Path $profileDir ("plugins\" + $name)
Write-Host "source : $Source"
Write-Host "dest   : $dest"

New-Item -ItemType Directory -Force -Path $dest | Out-Null
foreach ($item in @('lib', 'scripts', 'tools', 'assets', 'package.json', 'cordis.patch.yml', 'screenshots.json', 'README.md', 'README.zh-CN.md', 'LICENSE')) {
  $from = Join-Path $Source $item
  if (Test-Path -LiteralPath $from) {
    Copy-Item -LiteralPath $from -Destination $dest -Recurse -Force
    Write-Host "  copied $item"
  }
}

if (-not (Test-Path -LiteralPath $DshCmd)) { throw "dsh CLI not found: $DshCmd (pass -DshCmd)" }

Write-Host "registering with the profile (this needs write access to $profileDir) ..."
& $DshCmd plugin --profile $Profile add $dest
if ($LASTEXITCODE -ne 0) { throw "dsh plugin add failed with exit code $LASTEXITCODE" }

$profilePkg = Join-Path $profileDir 'package.json'
$after = (Get-Content -LiteralPath $profilePkg -Raw) | ConvertFrom-Json
Write-Host ""
Write-Host "registered bundles:"
$after.dsh.profile.bundles | ForEach-Object { Write-Host ("  " + $_) }
Write-Host ""
Write-Host "Now restart DSH (for example with the power plugin's restart button) to load the new code."
