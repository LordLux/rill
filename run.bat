@echo off

if exist .env (
  for /f "usebackq tokens=1,* delims==" %%A in (.env) do (
    if "%%A"=="YT_COOKIE" set "YT_COOKIE=%%~B"
  )
)

where fvm >nul 2>nul
if errorlevel 1 (
  set FLUTTER_CMD=flutter
) else (
  set FLUTTER_CMD=fvm flutter
)

echo Building sidecar...
cd sidecar
call bun run build
cd ..\app
echo Running Flutter app in release mode...
call %FLUTTER_CMD% run --release -d windows
cd ..
