# Task 07 - drive the media_kit harness N times and tally the verdicts.
#
# ASCII only, deliberately: Windows PowerShell 5.1 reads a .ps1 with no BOM as
# ANSI, and a stray em dash turns the whole file into a parser error.
#
# The harness is one build with a runtime switch (env vars, not --dart-define),
# so every run below is the same binary. Each run is a fresh process, which is
# how spike 05 ran its five: a fresh mpv, a fresh ANGLE context, and no state
# carried between them.
#
#   .\07-run.ps1 -Mode q1 -Runs 5                    # the seek baseline
#   .\07-run.ps1 -Mode q2 -Runs 1                    # stream-lavf-o reachability
#   .\07-run.ps1 -Mode q3 -Track av1 -Runs 1         # decoder, drops, CPU
#
# CPU comes from the harness itself (GetProcessTimes), not from here: the app
# decodes on its own threads inside its own process, and that is the number
# spike 05's `time.process_time()` reported.

param(
  [ValidateSet('q1', 'q2', 'q3')][string]$Mode = 'q1',
  [ValidateSet('av1', 'vp9', 'av1-1080', 'vp9-1080')][string]$Track = 'av1',
  [ValidateSet('baseline', 'request_size')][string]$Options = 'baseline',
  # Empty leaves media_kit's own default (auto). 'no' is Q3's software control.
  [string]$Hwdec = '',
  [string]$LogLevel = 'info',
  [int]$Runs = 5
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'app\build\windows\x64\runner\Release\native_youtube.exe'
$stream = Join-Path $root 'spiking\07-out\stream.json'
$outDir = Join-Path $root 'spiking\07-out'

if (-not (Test-Path $exe)) {
  throw "no build at $exe - run: cd app; flutter build windows --release"
}
if (-not (Test-Path $stream)) {
  throw "no stream at $stream - run: bun run spiking/07-resolve.ts"
}

# Stream URLs are ~6 h and IP-bound. A stale-URL 403 looks exactly like a
# media_kit fault from inside the harness, so refuse before measuring rather
# than debugging one.
$expires = (Get-Content $stream -Raw | ConvertFrom-Json).expiresAt
if ($expires -and ([datetime]$expires) -lt (Get-Date).ToUniversalTime()) {
  throw "stream URLs expired at $expires - re-resolve: bun run spiking/07-resolve.ts"
}

$env:NY_MODE = $Mode
$env:NY_TRACK = $Track
$env:NY_OPTIONS = $Options
$env:NY_STREAM_JSON = $stream
$env:NY_LOGLEVEL = $LogLevel
if ($Hwdec) { $env:NY_HWDEC = $Hwdec } else { Remove-Item Env:\NY_HWDEC -ErrorAction SilentlyContinue }
$tag = if ($Hwdec) { "$Options-hwdec-$Hwdec" } else { $Options }

$results = @()
for ($i = 1; $i -le $Runs; $i++) {
  $out = Join-Path $outDir "$Mode-$Track-$tag-run$i.json"
  $env:NY_RUN = "$i"
  $env:NY_OUT = $out
  Write-Host "run $i/$Runs  mode=$Mode track=$Track options=$Options" -ForegroundColor Cyan

  & $exe | Out-Null

  if (-not (Test-Path $out)) {
    Write-Host "  no verdict written" -ForegroundColor Red
    continue
  }
  $v = Get-Content $out -Raw | ConvertFrom-Json
  $results += $v
  Write-Host ("  seeks {0}/{1}  played={2}  hwdec={3}  decoder={4}  drops={5}  cpu={6}s ({7}s in run)" -f `
      $v.seeksOk, $v.seeksTotal, $v.played, $v.properties.'hwdec-current', `
      $v.properties.'current-tracks/video/decoder-desc', $v.dropsDuringRun, `
      [math]::Round($v.cpuSeconds, 1), [math]::Round($v.cpuDuringRunSeconds, 1))
}

Write-Host ''
Write-Host "=== $Mode / $Track / $tag ===" -ForegroundColor Green
$full = ($results | Where-Object { $_.seeksOk -eq $_.seeksTotal }).Count
Write-Host "runs at full marks: $full/$($results.Count)"
foreach ($r in $results) {
  $line = "run $($r.run): seeks $($r.seeksOk)/$($r.seeksTotal)"
  $line += " video=$($r.properties.'video-codec') hwdec=$($r.properties.'hwdec-current')"
  $line += " audio=$($r.properties.'audio-codec') tracks=$($r.properties.'track-list/count')"
  $line += " decoder=$($r.properties.'current-tracks/video/decoder-desc')"
  $line += " avsync=$($r.properties.avsync) drops=$($r.dropsDuringRun)"
  $line += " cpu=$([math]::Round($r.cpuSeconds, 2))s/$([math]::Round($r.cpuDuringRunSeconds, 2))s"
  $line += " mpv=$($r.properties.'mpv-version') api=$($r.mpvClientApiVersion)"
  $line += " lavf-o='$($r.streamLavfOptionsReadBack)'"
  Write-Host $line
}
