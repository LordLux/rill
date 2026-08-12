@echo off
setlocal
set RELEASE=app\build\windows\x64\runner\Release
set ARCHIVE=app\build\windows\x64\runner\NativeYouTube.zip

echo Building sidecar...
cd sidecar
call bun run build
cd ..\app
echo Building Flutter app...
call flutter build windows --release
cd ..

REM Bundle the sidecar INTO the release folder.
echo Bundling sidecar into the release folder...
if not exist "%RELEASE%\sidecar\dist" mkdir "%RELEASE%\sidecar\dist"
copy /Y "sidecar\dist\sidecar.exe" "%RELEASE%\sidecar\dist\sidecar.exe" >nul
if errorlevel 1 (
  echo   FAILED to copy the sidecar - the release folder will not run elsewhere.
) else (
  echo   ok: %RELEASE%\sidecar\dist\sidecar.exe
)

echo Zipping the release folder...
if exist "%ARCHIVE%" del "%ARCHIVE%"
powershell -Command "Compress-Archive -Path '%RELEASE%\*' -DestinationPath '%ARCHIVE%'"

echo Opening file explorer...
explorer "app\build\windows\x64\runner\Release"
endlocal
