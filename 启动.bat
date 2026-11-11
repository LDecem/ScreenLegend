@echo off
setlocal
set "HTML=%~dp0index.html"
if not exist "%HTML%" (
  echo Cannot find index.html next to this launcher.
  pause
  exit /b 1
)

rem Start the invisible overlay helper (serves http://127.0.0.1:8777 for the
rem borderless always-on-top legend window). A second copy exits by itself
rem because the port is already taken.
if exist "%~dp0tools\legend-overlay.ps1" (
  start "" /min powershell -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File "%~dp0tools\legend-overlay.ps1"
)

set "URL=file:///%HTML:\=/%"
set "EDGE=%ProgramFiles(x86)%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%ProgramFiles%\Microsoft\Edge\Application\msedge.exe"
if not exist "%EDGE%" set "EDGE=%LOCALAPPDATA%\Microsoft\Edge\Application\msedge.exe"
if exist "%EDGE%" (
  start "" "%EDGE%" --app="%URL%" --window-size=1280,900
) else (
  echo Microsoft Edge not found. Opening with the default browser...
  start "" "%HTML%"
)
endlocal
