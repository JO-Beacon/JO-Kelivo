@echo off
setlocal

cd /d "%~dp0"

if not exist "BUG\chats.json" (
  echo [ERROR] BUG\chats.json not found.
  echo.
  echo Put the chats.json file here:
  echo %~dp0BUG\chats.json
  echo.
  pause
  exit /b 2
)

where uv >nul 2>nul
if errorlevel 1 (
  echo [ERROR] uv command not found.
  echo.
  echo Install uv first, or run this command manually:
  echo python optimize_chat_archive.py BUG\chats.json
  echo.
  pause
  exit /b 3
)

if exist "BUG\chats.backup.json" del /f /q "BUG\chats.backup.json"

echo Optimizing BUG\\chats.json ...
echo.
uv run python optimize_chat_archive.py BUG\chats.json --overwrite-output
set "exit_code=%ERRORLEVEL%"
echo.

if not "%exit_code%"=="0" (
  echo [ERROR] Optimization failed. Exit code: %exit_code%
  echo Check the error output above.
  echo.
  pause
  exit /b %exit_code%
)

echo Optimization completed.
echo Output file: BUG\chats.optimized.json
echo Backup file: BUG\chats.backup.json
echo.
pause


