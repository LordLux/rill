@echo off
echo Building sidecar...
cd sidecar
call bun run build
cd ..\app
echo Running Flutter app in release mode...
call flutter run --release -d windows
cd ..
