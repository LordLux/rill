# rill — build, run, package and check the app. `rill --help` for the full surface.
# This file is the only implementation; rill.bat forwards to it so cmd works too.

# Any failing cmdlet or missing command stops the script. Without this, a
# `Set-Location` that fails carries on in the wrong directory, and a missing
# `bun` leaves $LASTEXITCODE unset, so `exit $LASTEXITCODE` reports success.
$ErrorActionPreference = 'Stop'

$Subcommands = @('build', 'run', 'open', 'flutter', 'zip', 'check')
$ReleaseDir = 'app\build\windows\x64\runner\Release'
$ArchiveFile = 'app\build\windows\x64\runner\NativeYouTube.zip'

function Show-Help {
    Write-Host 'Usage: rill <subcommand> [options]'
    Write-Host ''
    Write-Host 'Subcommands:'
    Write-Host '  build    Compile sidecar and app, bundle, and stop.'
    Write-Host '  run      Build, bundle, then launch the exe attached to this terminal.'
    Write-Host '           The terminal stays busy until the app exits; its exit code is rill''s.'
    Write-Host '  open     Launch the existing release build without building, attached like run.'
    Write-Host '           Warns if the bundled sidecar is older than sidecar/dist.'
    Write-Host '  flutter  Run ''fvm flutter run --release -d windows'' (lets the Flutter tool drive).'
    Write-Host '  zip      Build, bundle, and Compress-Archive into a zip, then open explorer.'
    Write-Host '  check    Run the test suite guard and the lint gate using the pinned SDK.'
    Write-Host ''
    Write-Host 'Options:'
    Write-Host '  --target <dart file>  Build or run another entrypoint (build, run, flutter, zip).'
    Write-Host '                        e.g.  rill run --target lib/probe_task19.dart'
    Write-Host '  --detach              (run, open) Launch detached and return immediately.'
    Write-Host '  -h, --help            Show this help message.'
    Write-Host ''
    Write-Host 'Works from any directory: paths are resolved from where this script lives.'
    Write-Host 'Exit codes: 0 success, 1 a step failed, 2 bad arguments; run returns the app''s own.'
    Write-Host ''
    Write-Host 'Hazards & Notes:'
    Write-Host '  - run and zip imply a build, so nobody ships or measures stale code.'
    Write-Host '  - The script copies sidecar/dist/sidecar.exe into the release folder. The app prefers'
    Write-Host '    the copy beside its own executable, and ''flutter build windows'' does not refresh'
    Write-Host '    an already-populated bundle. This script prevents running stale sidecar code.'
    Write-Host '  - It also copies the VC++ runtime (MSVCP140/VCRUNTIME140/VCRUNTIME140_1) from'
    Write-Host '    System32 into the release folder, the same three DLLs the release workflow stages,'
    Write-Host '    so a build/run/zip output still starts on a machine without them already installed.'
    Write-Host '  - It requires fvm (Flutter Version Management) and stops without it. Falling back to'
    Write-Host '    the global Flutter re-resolves app/pubspec.lock and breaks the next fvm command.'
    Write-Host '  - Loads YT_COOKIE from .env. A checkout can come up signed in with the variable unset'
    Write-Host '    in the environment.'
    Write-Host '  - For a fresh machine, run setup.bat first.'
}

function Stop-Usage([string]$Message) {
    [Console]::Error.WriteLine("rill: $Message")
    [Console]::Error.WriteLine("Run 'rill --help' for usage.")
    exit 2
}

# A native command's exit code is not an error to PowerShell, so every step is
# checked explicitly. A failed Flutter build must never go on to bundle and
# launch the previous release binary: it comes up, looks fine, and is old code.
function Invoke-Step([string]$Label, [scriptblock]$Command) {
    $global:LASTEXITCODE = 0
    & $Command
    if ($LASTEXITCODE -ne 0) { throw "$Label failed (exit $LASTEXITCODE)." }
}

function Get-ReleaseExe {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "$ReleaseDir\rill.exe"))
}

# Returns the app's exit code, or 0 when detached.
function Start-ReleaseApp([bool]$Detached) {
    $exe = Get-ReleaseExe
    if ($Detached) {
        Write-Host 'Launching application (detached)...'
        Start-Process -FilePath $exe | Out-Null
        return 0
    }
    Write-Host 'Launching application...'
    # rill.exe is a GUI-subsystem program, and PowerShell's `&` does not wait
    # for those: the prompt comes straight back and the app's output lands on
    # top of it. -NoNewWindow keeps it on this console (the runner attaches to
    # its parent's); -Wait holds the terminal until it exits.
    $proc = Start-Process -FilePath $exe -NoNewWindow -Wait -PassThru
    return $proc.ExitCode
}

# ---------------------------------------------------------------------------
# Arguments — anything unrecognised is an error, not a no-op. A mistyped
# `--traget` would otherwise build main.dart while you think you built a probe.
# ---------------------------------------------------------------------------

$Action = $null
$Target = $null
$Help = $false
$Detach = $false

for ($i = 0; $i -lt $args.Count; $i++) {
    $arg = "$($args[$i])"
    if ($Subcommands -contains $arg) {
        if ($Action) { Stop-Usage "one subcommand at a time ('$Action' and '$arg')" }
        $Action = $arg
    } elseif ($arg -eq '--detach') {
        $Detach = $true
    } elseif ($arg -eq '--target') {
        if ($i + 1 -ge $args.Count -or "$($args[$i + 1])".StartsWith('-')) {
            Stop-Usage '--target needs a Dart file, e.g. --target lib/probe_task19.dart'
        }
        $i++
        $Target = "$($args[$i])"
    } elseif ($arg -eq '-h' -or $arg -eq '--help') {
        $Help = $true
    } else {
        Stop-Usage "unrecognised argument '$arg'"
    }
}

if ($Help -or -not $Action) {
    Show-Help
    exit 0
}
if ($Detach -and $Action -notin @('run', 'open')) { Stop-Usage '--detach only applies to run and open' }
if ($Target -and $Action -eq 'check') { Stop-Usage '--target does not apply to check' }
if ($Target -and $Action -eq 'open') { Stop-Usage '--target does not apply to open: it opens whatever was last built' }

# ---------------------------------------------------------------------------
# Environment
# ---------------------------------------------------------------------------

if ($Action -ne 'open' -and -not (Get-Command 'fvm' -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('rill: fvm is not installed or not on PATH. The global Flutter is not a ' +
        'substitute: it re-resolves app/pubspec.lock and breaks the next fvm command. Install fvm, ' +
        'then run setup.bat.')
    exit 1
}
if ($Action -in @('build', 'run', 'zip') -and -not (Get-Command 'bun' -ErrorAction SilentlyContinue)) {
    [Console]::Error.WriteLine('rill: bun is not installed or not on PATH; it builds the sidecar.')
    exit 1
}

$envFile = Join-Path $PSScriptRoot '.env'
if (Test-Path $envFile) {
    foreach ($line in Get-Content $envFile) {
        if ($line -match '^\s*YT_COOKIE\s*=\s*(.*)$') {
            $value = $Matches[1].Trim()
            # Strip one pair of surrounding quotes, as build.bat's %%~B and Bun's
            # own .env loader both do. A variable set here wins over Bun's .env,
            # so a quoted value would reach the sidecar as a cookie that starts
            # with a quote — a sign-in that silently comes up anonymous.
            if ($value.Length -ge 2 -and $value[0] -eq $value[-1] -and ($value[0] -eq '"' -or $value[0] -eq "'")) {
                $value = $value.Substring(1, $value.Length - 2)
            }
            $env:YT_COOKIE = $value
        }
    }
}

# ---------------------------------------------------------------------------
# Work — always from the repo root, and always back where the caller was.
# ---------------------------------------------------------------------------

$exitCode = 0
Push-Location $PSScriptRoot
try {
    if ($Action -eq 'check') {
        Write-Host 'Running check...'
        Set-Location 'app'
        Invoke-Step 'test_suite_guard.dart' { fvm dart run tool/test_suite_guard.dart }
        Invoke-Step 'lint_gate.dart' { fvm dart run tool/lint_gate.dart }
        Write-Host 'Check passed.'
    } elseif ($Action -eq 'flutter') {
        Write-Host 'Running Flutter app in release mode...'
        Set-Location 'app'
        $flutterArgs = @('run', '--release', '-d', 'windows')
        if ($Target) { $flutterArgs += @('-t', $Target) }
        Invoke-Step 'flutter run' { fvm flutter @flutterArgs }
    } elseif ($Action -eq 'open') {
        $exe = Get-ReleaseExe
        if (-not (Test-Path $exe)) { throw "there is no release build at $exe yet. Run 'rill build' first." }

        # The trap CLAUDE.md spends its longest paragraph on: the app runs the
        # sidecar bundled beside it, not the one in sidecar/dist. After a
        # `bun run build` without a `rill build`, open would silently test the
        # old one, so say so. A warning, not a failure: opening an older build
        # on purpose is legitimate.
        $dist = Get-Item -ErrorAction SilentlyContinue 'sidecar\dist\sidecar.exe'
        $bundled = Get-Item -ErrorAction SilentlyContinue "$ReleaseDir\sidecar\dist\sidecar.exe"
        if (-not $bundled) {
            Write-Warning "the release build has no bundled sidecar, so the app will look for the repo's. Run 'rill build'."
        } elseif ($dist -and $dist.LastWriteTime -gt $bundled.LastWriteTime) {
            # `-f` binds tighter than `+`, so the whole message is joined first.
            $message = 'sidecar/dist is newer than the bundled sidecar ({0:yyyy-MM-dd HH:mm} vs {1:yyyy-MM-dd HH:mm}), ' +
                "so this runs the older one. Run 'rill build' to update it."
            Write-Warning ($message -f $dist.LastWriteTime, $bundled.LastWriteTime)
        }
        $exitCode = Start-ReleaseApp $Detach
    } else {
        # A running release app locks its own folder. MSBuild then spends ~15 s
        # retrying a DLL copy before failing with a wall of warnings, and the
        # sidecar copy below would fail the same way — say it plainly instead.
        $releaseExe = Get-ReleaseExe
        $running = @(Get-Process -Name 'rill' -ErrorAction SilentlyContinue |
            Where-Object { $_.Path -and $_.Path -ieq $releaseExe })
        if ($running.Count -gt 0) {
            throw "the release app is running (PID $($running.Id -join ', ')) and locks its folder. Close it and try again."
        }

        Write-Host 'Building sidecar...'
        Set-Location 'sidecar'
        Invoke-Step 'bun run build' { bun run build }
        Set-Location $PSScriptRoot

        Write-Host 'Building Flutter app...'
        Set-Location 'app'
        $flutterArgs = @('build', 'windows', '--release')
        if ($Target) { $flutterArgs += @('-t', $Target) }
        Invoke-Step 'flutter build' { fvm flutter @flutterArgs }
        Set-Location $PSScriptRoot

        # Bundle the sidecar INTO the release folder.
        # Without this the folder is not self-contained: the app finds the sidecar by
        # looking beside its own executable first and then walking up from the working
        # directory, and on any machine without a checkout neither exists. The symptom
        # is "Failed to start sidecar process", which reads like the sidecar crashed
        # rather than like it was never shipped.
        Write-Host 'Bundling sidecar into the release folder...'
        New-Item -ItemType Directory -Force -Path "$ReleaseDir\sidecar\dist" | Out-Null
        Copy-Item -Force 'sidecar\dist\sidecar.exe' "$ReleaseDir\sidecar\dist\sidecar.exe"
        Write-Host "  ok: $ReleaseDir\sidecar\dist\sidecar.exe"

        # App-local copies of the VC++ runtime, the same three DLLs and the same
        # source .github/workflows/release.yml stages before packaging (its
        # comment: "these three DLLs are what Microsoft's redistribution terms
        # allow"). Without them rill.exe fails before any of our code runs —
        # "MSVCP140.dll was not found" — on any machine that doesn't already
        # have the redistributable installed for some other reason, which is
        # every dev machine that has Visual Studio but no genuinely clean one.
        # Measured 2026-09-28: a `rill build` output installed into a fresh
        # Windows Sandbox hit exactly this before this step existed.
        Write-Host 'Bundling the VC++ runtime into the release folder...'
        $system32 = Join-Path $env:SystemRoot 'System32'
        foreach ($dll in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll')) {
            Copy-Item -Force (Join-Path $system32 $dll) "$ReleaseDir\$dll"
            Write-Host "  ok: $ReleaseDir\$dll"
        }

        if ($Action -eq 'zip') {
            Write-Host 'Zipping the release folder...'
            Compress-Archive -Force -Path "$ReleaseDir\*" -DestinationPath $ArchiveFile
            Write-Host "  ok: $ArchiveFile"
            Write-Host 'Opening file explorer...'
            Invoke-Item $ReleaseDir
        } elseif ($Action -eq 'run') {
            $exitCode = Start-ReleaseApp $Detach
        }
    }
} catch {
    [Console]::Error.WriteLine("rill: $($_.Exception.Message)")
    $exitCode = 1
} finally {
    Pop-Location
}
exit $exitCode
