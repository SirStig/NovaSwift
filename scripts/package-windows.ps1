<#
.SYNOPSIS
  Build the NOVA Swift Godot package for Windows x86_64 (run on a Windows PC).
.DESCRIPTION
  Needs (all on PATH): Swift 6.x for Windows (swift.org installer, incl. Visual Studio Build Tools +
  Windows SDK), Git, Docker Desktop (Linux containers; builds the bundled movie decoder the first
  time, see scripts/build-mini-ffmpeg.sh), and Godot 4.7.2 (godot.exe / console build) with the Windows export template
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
# Bundled decode-only ffmpeg for the original movies. Built once (mingw-w64 cross-build in the same
# swift:6.3-jammy container the Linux package uses) and cached in godot\bin\ffmpeg\windows\.
$Ff = "godot\bin\ffmpeg\windows"
if (-not (Test-Path "$Ff\ffmpeg.exe")) {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "godot\bin\ffmpeg\windows\ffmpeg.exe missing and docker not found: install Docker Desktop, or copy that folder from a machine that ran scripts/build-mini-ffmpeg.sh windows"
    }
    Write-Host "Building bundled ffmpeg (first time only, ~10 min)..."
    docker run --rm --platform linux/amd64 -v "${PWD}:/work" -w /work swift:6.3-jammy bash -lc "scripts/build-mini-ffmpeg.sh windows"
    if ($LASTEXITCODE -or -not (Test-Path "$Ff\ffmpeg.exe")) { throw "bundled ffmpeg build failed (see .ffmpeg-build\*-windows.log)" }
}
Copy-Item "$Ff\ffmpeg.exe" "$Out\ffmpeg.exe"
Copy-Item "$Ff\LICENSE.txt" "$Out\FFMPEG-LICENSE.txt"
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
# The bundled ffmpeg must run on this machine (decode-only: no Theora encoder, mjpeg present).
$enc = & "$Out\ffmpeg.exe" -hide_banner -encoders 2>&1 | Out-String
if ($LASTEXITCODE -or $enc -notmatch " mjpeg ") { throw "bundled ffmpeg.exe does not run: $enc" }
Compress-Archive -Path "$Out\*" -DestinationPath $Zip -Force
Write-Host "OK $Zip"
Write-Host "Next (release): scripts/release-sign.sh --version X.Y.Z --asset windows-x86_64=$Zip   (docs/UPDATER.md)"
