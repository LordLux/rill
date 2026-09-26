# Starts a compiled sidecar and checks that it announces itself.
#
#   release\smoke-sidecar.ps1 -Sidecar <path to sidecar.exe>
#
# The sidecar prints `event.ready` before it reads a single request, so closing
# stdin straight away is enough: what this proves is that the executable starts at
# all on this machine — the bun runtime is embedded and the entry module loads.
# A packaging mistake (wrong file, stale copy, blocked DLL) fails here in seconds
# rather than as "Failed to start sidecar process" in a user's app.
param(
    [Parameter(Mandatory)] [string] $Sidecar,
    [int] $TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $Sidecar)) { throw "no sidecar at $Sidecar" }

$info = New-Object System.Diagnostics.ProcessStartInfo (Resolve-Path -LiteralPath $Sidecar).Path
$info.UseShellExecute = $false
$info.RedirectStandardInput = $true
$info.RedirectStandardOutput = $true
$info.RedirectStandardError = $true

$process = [System.Diagnostics.Process]::Start($info)
try {
    $process.StandardInput.Close()
    # stderr is protocol-free logging; drain it so a full pipe cannot stall startup.
    $null = $process.StandardError.ReadToEndAsync()
    $read = $process.StandardOutput.ReadLineAsync()
    if (-not $read.Wait([TimeSpan]::FromSeconds($TimeoutSeconds))) {
        throw "the sidecar printed nothing within $TimeoutSeconds s"
    }
    $line = $read.Result
    if ($line -notmatch '"method"\s*:\s*"event\.ready"') {
        throw "the sidecar's first line was not event.ready: $line"
    }
    Write-Host "ok: $line"
} finally {
    if (-not $process.HasExited) {
        if (-not $process.WaitForExit(10000)) { $process.Kill() }
    }
}
