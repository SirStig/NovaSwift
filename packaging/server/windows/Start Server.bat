@echo off
rem NovaSwift Dedicated Server: double-click to start. The window shows the admin address and password.
rem Keep this window open while the server runs. Close it (or press Ctrl+C) to stop.
cd /d "%~dp0"
title NovaSwift Dedicated Server
NovaSwiftServer.exe
echo.
echo The server stopped. Press any key to close.
pause >nul
