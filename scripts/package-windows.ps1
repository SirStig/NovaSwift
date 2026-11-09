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
$customWin = if ($env:CUSTOM_WINDOWS_TEMPLATE) { $env:CUSTOM_WINDOWS_TEMPLATE } else { "godot\export_templates\windows_release_x86_64.exe" }
$presetsBak = $null
if (Test-Path $customWin) {
  Write-Host "Using thin custom Windows template: $customWin"
  $presetsBak = [System.IO.Path]::GetTempFileName()
  Copy-Item godot\export_presets.cfg $presetsBak -Force
  $abs = (Resolve-Path $customWin).Path -replace '\\', '/'
  $cfg = Get-Content godot\export_presets.cfg -Raw
  $cfg2 = [regex]::Replace($cfg, '(?ms)(\[preset\.1\.options\].*?)^custom_template/release=.*$', "`$1custom_template/release=`"$abs`"", 1)
  if ($cfg2 -eq $cfg) { throw "failed to patch Windows custom_template/release" }
  Set-Content godot\export_presets.cfg $cfg2 -NoNewline
}
try {
  & $Godot --headless --path godot --export-release "Windows" "$PWD\$Out\NovaSwift.exe"
} finally {
  if ($presetsBak -and (Test-Path $presetsBak)) {
    Move-Item $presetsBak godot\export_presets.cfg -Force
  }
}
if (-not (Test-Path "$Out\NovaSwift.exe")) { throw "export failed (Windows export template installed?)" }
# Godot copies NovaSwiftGodot.dll + SwiftGodot.dll via the .gdextension; add only the Swift
# runtime DLLs the bridge actually needs (not the whole runtime directory — that pulled in
# swiftRemoteMirror, SwiftOnoneSupport, Differentiation, etc.).
foreach ($n in "NovaSwiftGodot.dll", "SwiftGodot.dll") { if (-not (Test-Path "$Out\$n")) { Copy-Item "$Bin\$n" $Out } }
function Get-DllDependents([string]$Path) {
  $dumpbin = Get-Command dumpbin.exe -ErrorAction SilentlyContinue
  if (-not $dumpbin) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
      $msvc = & $vswhere -latest -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -find "**\dumpbin.exe" | Select-Object -First 1
      if ($msvc) { $dumpbin = @{ Source = $msvc } }
    }
  }
  if (-not $dumpbin) { return @() }
  $out = & $dumpbin.Source /DEPENDENTS $Path 2>$null | Out-String
  return [regex]::Matches($out, '(?im)^\s+([A-Za-z0-9_\-\.]+\.dll)\s*$') | ForEach-Object { $_.Groups[1].Value }
}
$needed = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$queue = New-Object System.Collections.Generic.Queue[string]
foreach ($n in "NovaSwiftGodot.dll", "SwiftGodot.dll") { $queue.Enqueue((Join-Path $Out $n)) }
# Always keep the core Swift / Foundation set even if dumpbin is missing.
foreach ($n in @(
  'swiftCore.dll','swiftCRT.dll','swiftWinSDK.dll','swiftDispatch.dll','dispatch.dll','BlocksRuntime.dll',
  'swift_Concurrency.dll','swift_StringProcessing.dll','swift_RegexParser.dll',
  'Foundation.dll','FoundationInternationalization.dll','FoundationNetworking.dll','FoundationXML.dll',
  '_FoundationICU.dll'
)) { [void]$needed.Add($n) }
while ($queue.Count -gt 0) {
  $dll = $queue.Dequeue()
  foreach ($dep in Get-DllDependents $dll) {
    if ($needed.Add($dep)) {
      $candidate = Join-Path $rtBin $dep
      if (Test-Path $candidate) { $queue.Enqueue($candidate) }
    }
  }
}
# Never ship debug / tooling DLLs even if somehow referenced.
foreach ($skip in @('swiftRemoteMirror.dll','swiftSwiftOnoneSupport.dll','swift_Differentiation.dll','swift_Testing.dll','Testing.dll')) {
  [void]$needed.Remove($skip)
}
$copied = 0
foreach ($n in $needed) {
  $src = Join-Path $rtBin $n
  if (Test-Path $src) { Copy-Item $src $Out -Force; $copied++ }
}
Write-Host "Swift runtime DLLs copied: $copied (from dependency walk + core set)"
# Strip debug info from bridge + Swift DLLs when llvm-strip / strip is available.
$strip = @(Get-Command llvm-strip.exe, strip.exe -ErrorAction SilentlyContinue | Select-Object -First 1)
if ($strip) {
  Get-ChildItem "$Out\*.dll" | ForEach-Object {
    & $strip.Source --strip-unneeded $_.FullName 2>$null
  }
  Write-Host "Stripped DLLs with $($strip.Source)"
}
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
