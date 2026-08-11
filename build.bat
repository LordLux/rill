@echo off
setlocal
set RELEASE=app\build\windows\x64\runner\Release

echo Building sidecar...
cd sidecar
call bun run build
cd ..\app
echo Building Flutter app...
call flutter build windows --release
cd ..

REM Bundle the sidecar INTO the release folder.
REM
REM Without this the folder is not self-contained: the app finds the sidecar by
REM looking beside its own executable first and then walking up from the working
REM directory, and on any machine without a checkout neither exists. The symptom
REM is "Failed to start sidecar process", which reads like the sidecar crashed
REM rather than like it was never shipped.
echo Bundling sidecar into the release folder...
if not exist "%RELEASE%\sidecar\dist" mkdir "%RELEASE%\sidecar\dist"
copy /Y "sidecar\dist\sidecar.exe" "%RELEASE%\sidecar\dist\sidecar.exe" >nul
if errorlevel 1 (
  echo   FAILED to copy the sidecar - the release folder will not run elsewhere.
) else (
  echo   ok: %RELEASE%\sidecar\dist\sidecar.exe
)

echo Launching application...
start "" "%RELEASE%\rill.exe"
endlocal
