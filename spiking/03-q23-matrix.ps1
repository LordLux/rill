# Spike 03 — the matrix that answers Q2 check 4 and Q3 together.
#
# Q2's first pass found ANDROID_VR URLs play and hardware-decode, then stall on a
# mid-file seek — not because the URL refuses a repositioned request (it answers
# 206 at every offset from a plain HTTP client) but because ffmpeg chose to
# soft-seek: "draining 694816224 remaining byte(s)" through the open connection
# instead of reconnecting.
#
# Q3's option is the direct answer to that, and it also landed under a different
# name than the task expected: upstream merged it as `request_size`, not
# `max_request_size`.
#
# So both questions are one matrix: client x request_size/short_seek_size.
#
#   powershell -File 03-q23-matrix.ps1

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '03-out'

# --- resolve MWEB through the sidecar's own ladder (deciphered n) -------------
Write-Host "resolving MWEB via sidecar probe..." -ForegroundColor Cyan
$probeLog = Join-Path $out 'q3-probe.log'
$pp = Start-Process -FilePath 'bun' -ArgumentList @('run','probe','aqz-KE-bpKQ') `
      -WorkingDirectory (Join-Path $here '..\sidecar') -NoNewWindow -PassThru `
      -RedirectStandardOutput "$probeLog.out" -RedirectStandardError $probeLog
$pp.WaitForExit()
$probe = (Get-Content $probeLog -Raw) + (Get-Content "$probeLog.out" -Raw -ErrorAction SilentlyContinue)
$m = [regex]::Match($probe, 'mpv "([^"]+)" --audio-file="([^"]+)"')
if (-not $m.Success) { throw "could not parse URLs out of probe output" }
$mwebVideo = $m.Groups[1].Value
$mwebAudio = $m.Groups[2].Value
Write-Host "  MWEB video itag $([regex]::Match($mwebVideo,'itag=(\d+)').Groups[1].Value), audio itag $([regex]::Match($mwebAudio,'itag=(\d+)').Groups[1].Value)"

$vr = Get-Content (Join-Path $out 'q2-urls.json') -Raw | ConvertFrom-Json
Write-Host "  ANDROID_VR video itag $($vr.av1.itag), audio itag $($vr.audio.itag)`n"

# --- the matrix ---------------------------------------------------------------
$RS = 1048576   # 1 MB, the value the task suggested for max_request_size

$cases = @(
  @{ name = 'MWEB  baseline';               video = $mwebVideo; audio = $mwebAudio; opts = $null },
  @{ name = 'MWEB  request_size';           video = $mwebVideo; audio = $mwebAudio; opts = "request_size=$RS" },
  @{ name = 'MWEB  request+short_seek';     video = $mwebVideo; audio = $mwebAudio; opts = "request_size=$RS,short_seek_size=$RS" },
  @{ name = 'VR    baseline';               video = $vr.av1.url; audio = $vr.audio.url; opts = $null },
  @{ name = 'VR    request_size';           video = $vr.av1.url; audio = $vr.audio.url; opts = "request_size=$RS" },
  @{ name = 'VR    request+short_seek';     video = $vr.av1.url; audio = $vr.audio.url; opts = "request_size=$RS,short_seek_size=$RS" }
)

$rows = @()
foreach ($c in $cases) {
  $slug = ($c.name -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLower()
  $log  = Join-Path $out "q23-$slug.log"

  $mpvArgs = @(
    '--no-config', '--hwdec=auto', '--vo=null', '--ao=null', '--keep-open=no',
    '--msg-level=all=info,vd=v,ffmpeg=v',
    "--script=$(Join-Path $here '03-seek.lua')",
    "--audio-file=$($c.audio)"
  )
  if ($c.opts) { $mpvArgs += "--stream-lavf-o=$($c.opts)" }
  $mpvArgs += $c.video

  $p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
  $p.WaitForExit()

  $text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + "`n" +
          (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)

  $verdict = ([regex]::Match($text, 'SPIKE VERDICT[^\r\n]*')).Value
  $err403  = if ($text -match '403 Forbidden|HTTP error 403') { 'yes' } else { 'no' }
  $soft    = ([regex]::Matches($text, 'Soft-seeking to offset')).Count
  $optbad  = if ($text -match "Option .* not found") { 'OPTION NOT FOUND' } else { '' }

  $loaded  = $verdict -match 'loaded=true'
  $played  = $verdict -match 'played=true'
  $seekOk  = $verdict -match 'seek_ok=true'

  $tone = if ($seekOk) { 'Green' } elseif ($played) { 'Yellow' } else { 'Red' }
  Write-Host ("{0,-26} loaded={1,-5} played={2,-5} seek_ok={3,-5} 403={4,-3} softseek={5} {6}" -f `
    $c.name, $loaded, $played, $seekOk, $err403, $soft, $optbad) -ForegroundColor $tone
  if ($verdict) { Write-Host "    $verdict" -ForegroundColor DarkGray }

  $rows += [pscustomobject]@{
    case = $c.name; opts = $c.opts; loaded = $loaded; played = $played
    seek_ok = $seekOk; http403 = $err403; softseeks = $soft; verdict = $verdict
  }
}

$rows | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'q23-matrix.json') -Encoding utf8
Write-Host "`nresults -> 03-out\q23-matrix.json"
