# Spike 03 / Q2 check 4 — mpv plays an ANDROID_VR URL, audio in sync, seek works.
#
# Also answers the codec question: Task 02 saw ANDROID_VR return AV1 (itag 401)
# where MWEB returned VP9 (itag 315). AV1 4K hardware decode needs a relatively
# recent GPU, so this runs both and records what mpv reports plus the CPU time
# each burned.
#
#   powershell -File 03-q2-mpv.ps1 [av1|vp9|both]

param([string]$Which = 'both')

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$urls = Get-Content (Join-Path $here '03-out\q2-urls.json') -Raw | ConvertFrom-Json
$logDir = Join-Path $here '03-out'

Write-Host "GPU:" -ForegroundColor Cyan
Get-CimInstance Win32_VideoController | ForEach-Object {
  Write-Host ("  {0}  driver {1}  {2} MB" -f $_.Name, $_.DriverVersion, [math]::Round($_.AdapterRAM/1MB))
}
& $mpv --version | Select-Object -First 2 | ForEach-Object { Write-Host "  $_" }
Write-Host ""

$targets = @()
if ($Which -eq 'both' -or $Which -eq 'av1') { $targets += ,@('av1', $urls.av1) }
if ($Which -eq 'both' -or $Which -eq 'vp9') { $targets += ,@('vp9', $urls.vp9) }

foreach ($t in $targets) {
  $name = $t[0]
  $fmt  = $t[1]
  if (-not $fmt.url) { continue }

  $log = Join-Path $logDir "q2-mpv-$name.log"
  Write-Host ("=== {0}  itag {1}  {2} ===" -f $name, $fmt.itag, $fmt.mimeType) -ForegroundColor Cyan

  $mpvArgs = @(
    '--no-config',
    '--hwdec=auto',
    '--vo=gpu',
    '--force-window=yes',
    '--keep-open=no',
    '--msg-level=all=info,vd=v,ffmpeg=v,stream=v,cache=v',
    "--script=$(Join-Path $here '03-seek.lua')",
    "--audio-file=$($urls.audio.url)",
    $fmt.url
  )

  $p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
  $p.WaitForExit()

  $cpu  = $p.TotalProcessorTime.TotalSeconds
  $wall = ($p.ExitTime - $p.StartTime).TotalSeconds
  Write-Host ("exit={0}  wall={1:N1}s  cpu={2:N1}s  ({3:N0}% of one core)" -f `
    $p.ExitCode, $wall, $cpu, (100 * $cpu / [math]::Max($wall,1)))

  $text = (Get-Content $log -Raw) + (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)
  $text -split "`n" | Where-Object {
    $_ -match 'SPIKE|hardware decoding|software decoding|Using hardware|hwdec|HTTP error|403|Failed to open|Cannot open'
  } | ForEach-Object { Write-Host "  $($_.Trim())" }
  Write-Host ""
}
