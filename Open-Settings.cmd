@echo off
setlocal
set "GUI_SCRIPT=%~dp0scripts\Settings-Gui.ps1"
if not exist "%GUI_SCRIPT%" (
  echo Missing settings tool: "%GUI_SCRIPT%"
  pause
  exit /b 1
)
start "" "%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "%GUI_SCRIPT%"
exit /b 0
