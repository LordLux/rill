@echo off
setlocal enabledelayedexpansion
cd /d "%~dp0"

where fvm >nul 2>nul
if errorlevel 1 (
  echo FVM is not installed or not on PATH. Falling back to global Flutter/Dart.
  set FLUTTER_CMD=flutter
  set DART_CMD=dart
  goto :dependencies
)

set FLUTTER_CMD=fvm flutter
set DART_CMD=fvm dart

echo [1/4] Ensuring the correct Flutter version is selected...
call fvm install 3.44.9
call fvm use 3.44.9
if errorlevel 1 (
  echo Failed to select the required Flutter SDK via FVM.
  exit /b %errorlevel%
)

:dependencies
echo [2/4] Installing app dependencies...
cd /d "%~dp0app"
call %FLUTTER_CMD% pub get
if errorlevel 1 (
  echo Failed to install app dependencies.
  exit /b %errorlevel%
)

call %FLUTTER_CMD% pub run build_runner build --delete-conflicting-outputs
if errorlevel 1 (
  echo Failed to generate Freezed/JSON code.
  exit /b %errorlevel%
)

echo [3/4] Installing custom lint plugin dependencies...
cd /d "%~dp0app\tool\rill_lints"
call %DART_CMD% pub get
if errorlevel 1 (
  echo Failed to install lint plugin dependencies.
  exit /b %errorlevel%
)

call %DART_CMD% analyze
if errorlevel 1 (
  echo Lint plugin package analysis failed.
  exit /b %errorlevel%
)

echo [4/4] Running project analysis...
cd /d "%~dp0app"
call %DART_CMD% run tool\lint_gate.dart
if errorlevel 1 (
  echo Project analysis failed.
  exit /b %errorlevel%
)

echo.
echo Setup complete. The repo is ready to open in VS Code / run the app.
endlocal
