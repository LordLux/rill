@echo off
echo Building sidecar...
cd sidecar
call bun run build
cd ..\app
echo Building Flutter app...
call flutter build windows --release
cd ..
echo Launching application...
start "" "app\build\windows\x64\runner\Release\native_youtube.exe"
