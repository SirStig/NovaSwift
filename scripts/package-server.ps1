# Build NovaSwiftServer-windows-x86_64.zip on a Windows PC (needs the Swift toolchain for Windows and Git).
#   powershell -ExecutionPolicy Bypass -File scripts\package-server.ps1
# STATUS: not run on Windows yet. NovaSwiftENet's UDPDiscovery and the HTTP layer use POSIX sockets
# (getifaddrs, poll); a Winsock port may be needed before this compiles. See docs/DEDICATED_SERVER.md.
$ErrorActionPreference = "Stop"
Set-Location (Join-Path $PSScriptRoot "..")
$out = "dist\server"; New-Item -ItemType Directory -Force $out | Out-Null
swift build -c release --product novaswift-server --scratch-path .build-server-windows
if ($LASTEXITCODE -ne 0) { throw "swift build failed" }
$stage = Join-Path $out "stage-windows"
Remove-Item -Recurse -Force $stage -ErrorAction SilentlyContinue
New-Item -ItemType Directory $stage | Out-Null
Copy-Item ".build-server-windows\release\novaswift-server.exe" (Join-Path $stage "NovaSwiftServer.exe")
Get-ChildItem ".build-server-windows\release\*.dll" -ErrorAction SilentlyContinue | Copy-Item -Destination $stage
Copy-Item "packaging\server\windows\Start Server.bat" $stage
Copy-Item "packaging\server\README.txt" $stage
$zip = Join-Path $out "NovaSwiftServer-windows-x86_64.zip"
Remove-Item $zip -ErrorAction SilentlyContinue
Compress-Archive -Path "$stage\*" -DestinationPath $zip
Remove-Item -Recurse -Force $stage
Write-Host "-> $zip"
