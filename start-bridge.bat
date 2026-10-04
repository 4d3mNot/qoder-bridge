@echo off
title Qoder Bridge
cd /d "%~dp0bridge-server"

rem Already running? Say so instead of failing with a stack trace.
netstat -ano | findstr ":8346" | findstr "LISTENING" >nul
if not errorlevel 1 (
  echo The bridge is already listening on 127.0.0.1:8346.
  echo Leave that window open, or close it to stop the bridge.
  pause
  exit /b 0
)

echo Starting the Qoder Bridge on 127.0.0.1:8346...
node server.js

echo.
echo The bridge stopped. Studio reconnects to it by itself within a few seconds
echo once it is running again. Press any key to close this window.
pause >nul
