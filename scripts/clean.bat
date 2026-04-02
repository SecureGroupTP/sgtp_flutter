@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM SGTP local data reset helper (Windows).
REM Usage:
REM   scripts\clean.bat
REM   scripts\clean.bat --yes

set "ASSUME_YES=0"
if /I "%~1"=="--yes" set "ASSUME_YES=1"

set "COUNT=0"

call :ADD_IF_EXISTS "%USERPROFILE%\Documents\sgtp"
call :ADD_IF_EXISTS "%USERPROFILE%\Documents\sgtp_accounts"
call :ADD_IF_EXISTS "%USERPROFILE%\Documents\sgtp_chats"

call :SCAN_PREFS "%APPDATA%"
call :SCAN_PREFS "%LOCALAPPDATA%"

if %COUNT% EQU 0 (
  echo Nothing to clean.
  exit /b 0
)

echo Will remove %COUNT% path(s):
for /L %%i in (1,1,%COUNT%) do echo   !P[%%i]!

if %ASSUME_YES% EQU 0 (
  set /p CONFIRM=Proceed? [y/N] 
  if /I not "!CONFIRM!"=="y" if /I not "!CONFIRM!"=="yes" (
    echo Cancelled.
    exit /b 0
  )
)

set "REMOVED=0"
for /L %%i in (1,1,%COUNT%) do (
  set "TARGET=!P[%%i]!"
  if exist "!TARGET!" (
    if exist "!TARGET!\" (
      rmdir /s /q "!TARGET!"
    ) else (
      del /f /q "!TARGET!"
    )
    set /a REMOVED+=1
  )
)

echo Done. Removed !REMOVED! path(s).
exit /b 0

:ADD_IF_EXISTS
if exist "%~1" (
  set /a COUNT+=1
  set "P[%COUNT%]=%~1"
)
exit /b 0

:SCAN_PREFS
set "ROOT=%~1"
if not exist "%ROOT%" exit /b 0
for /r "%ROOT%" %%F in (shared_preferences.json) do (
  findstr /m /c:"\"sgtp_" "%%~fF" >nul 2>&1
  if not errorlevel 1 call :ADD_IF_EXISTS "%%~fF"
)
exit /b 0
