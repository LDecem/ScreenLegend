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

  rem PowerShell needs a moment before the helper answers. Wait for it, so the
  rem very first pick already uses the native picker (which supports
  rem right-click cancel) instead of the browser EyeDropper fallback.
  where curl >nul 2>nul
  if errorlevel 1 (
    ping -n 3 127.0.0.1 >nul
    goto helperReady
  )
  for /l %%i in (1,1,12) do (
    curl -s -o nul --max-time 1 http://127.0.0.1:8777/state
    if not errorlevel 1 goto helperReady
    ping -n 2 127.0.0.1 >nul
  )
)
:helperReady

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
