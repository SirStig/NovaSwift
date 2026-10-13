<#
.SYNOPSIS
  Build the NOVA Swift Godot package for Windows x86_64 (run on a Windows PC).
.DESCRIPTION
  Needs (all on PATH): Swift 6.x for Windows (swift.org installer, incl. Visual Studio Build Tools +
  Windows SDK), Git, and Godot 4.7.2 (godot.exe / console build) with the Windows export template
  installed (Editor > Manage Export Templates, or %APPDATA%\Godot\export_templates\4.7.2.stable\).
  Output: godot\export\NovaSwift-windows-x86_64.zip. No EV Nova data is included (BYO-data).
  Usage:  powershell -ExecutionPolicy Bypass -File scripts\package-windows.ps1 [-Godot C:\path\godot.exe] [-SkipBuild]
#>
param([string]$Godot = "godot", [switch]$SkipBuild)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path $PSScriptRoot -Parent)
$Bin = "godot\bin"; $Out = "godot\export\windows"; $Zip = "godot\export\NovaSwift-windows-x86_64.zip"
New-Item -ItemType Directory -Force $Bin, $Out | Out-Null

if (-not $SkipBuild) {
  swift --version
  swift build --package-path godot\bridge -c release -Xswiftc -no-verify-emitted-module-interface
  if ($LASTEXITCODE) { throw "swift build failed" }
  $bp = (swift build --package-path godot\bridge -c release -Xswiftc -no-verify-emitted-module-interface --show-bin-path).Trim()
  # SwiftPM emits NovaSwiftGodot.dll / SwiftGodot.dll (some versions prefix lib); the .gdextension wants no prefix.
  foreach ($n in "NovaSwiftGodot", "SwiftGodot") {
    $src = @("$bp\$n.dll", "$bp\lib$n.dll") | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $src) { throw "$n.dll not found in $bp" }
    Copy-Item $src "$Bin\$n.dll" -Force
  }
}
foreach ($n in "NovaSwiftGodot.dll", "SwiftGodot.dll") { if (-not (Test-Path "$Bin\$n")) { throw "$Bin\$n missing" } }

# Swift runtime DLLs the bridge needs (swiftCore, Foundation, dispatch, ICU ...). They live in the
# toolchain's runtime dir; copy every DLL from the newest installed runtime that the bridge imports.
$rt = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes" -Directory -ErrorAction SilentlyContinue |
      Sort-Object Name -Descending | Select-Object -First 1
if (-not $rt) { $rt = Get-ChildItem "$env:ProgramFiles\Swift\runtime-*" -Directory -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1 }
$rtBin = if ($rt) { Join-Path $rt.FullName "usr\bin" } else { $null }
if (-not $rtBin -or -not (Test-Path $rtBin)) { throw "Swift runtime dir not found; set `$rtBin manually (look for swiftCore.dll)" }
Write-Host "Swift runtime: $rtBin"

Remove-Item $Out -Recurse -Force -ErrorAction SilentlyContinue; New-Item -ItemType Directory -Force $Out | Out-Null
& $Godot --headless --path godot --import 2>$null | Out-Null
& $Godot --headless --path godot --export-release "Windows" "$PWD\$Out\NovaSwift.exe"
if (-not (Test-Path "$Out\NovaSwift.exe")) { throw "export failed (Windows export template installed?)" }
# Godot copies NovaSwiftGodot.dll + SwiftGodot.dll via the .gdextension; add the Swift runtime beside them.
Copy-Item "$rtBin\*.dll" $Out -Force
foreach ($n in "NovaSwiftGodot.dll", "SwiftGodot.dll") { if (-not (Test-Path "$Out\$n")) { Copy-Item "$Bin\$n" $Out } }
Copy-Item godot\icon.png "$Out\icon.png"
@"
NOVA Swift - Windows build
Run NovaSwift.exe (NovaSwift.console.exe shows a log window).
Needs the Microsoft Visual C++ Redistributable (x64). This package contains NO game data:
put your own EV Nova data in %USERPROFILE%\.local\share\NovaSwift\data, or pick the folder in the in-game "Game Data" screen.
"@ | Set-Content "$Out\README.txt"

# Smoke test: extension must load.
$log = & "$Out\NovaSwift.console.exe" --headless --quit-after 60 2>&1 | Out-String
Write-Host $log
if ($log -match "Can't open dynamic library|SCRIPT ERROR|Error loading extension") { throw "smoke test failed" }
Compress-Archive -Path "$Out\*" -DestinationPath $Zip -Force
Write-Host "OK $Zip"
Write-Host "Next (release): scripts/release-sign.sh --version X.Y.Z --asset windows-x86_64=$Zip   (docs/UPDATER.md)"
