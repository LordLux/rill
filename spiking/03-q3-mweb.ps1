# Spike 03 / Q3 - does bounding the request rescue MWEB?
#
# The matrix said no: MWEB 403s with request_size set. Before recording that,
# check whether the option is even reaching the request that fails. Upstream
# landed two options, not one:
#
#   initial_request_size  (2026-01-23) size of initial requests made during
#                                      probing / header parsing
#   request_size          (2026-02-09) size of requests to make
#
# If the probing request is still open-ended, MWEB 403s before request_size ever
# applies - and the fix would be the other option. This traces the actual Range
# header on the wire for each combination.

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '03-out'

$probe = Get-Content (Join-Path $out 'q3-probe.log') -Raw
$m = [regex]::Match($probe, 'mpv "([^"]+)" --audio-file="([^"]+)"')
if (-not $m.Success) { throw "no URLs in q3-probe.log - re-run 03-q23-matrix.ps1 first" }
$video = $m.Groups[1].Value
$audio = $m.Groups[2].Value

$RS = 1048576
$cases = @(
  @{ n = 'baseline';                        o = $null },
  @{ n = 'request_size';                    o = "request_size=$RS" },
  @{ n = 'initial_request_size';            o = "initial_request_size=$RS" },
  @{ n = 'initial + request';               o = "initial_request_size=$RS,request_size=$RS" },
  @{ n = 'initial + request + short_seek';  o = "initial_request_size=$RS,request_size=$RS,short_seek_size=$RS" }
)

foreach ($c in $cases) {
  $slug = ($c.n -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLower()
  $log  = Join-Path $out "q3-mweb-$slug.log"

  $mpvArgs = @(
    '--no-config', '--hwdec=auto', '--vo=null', '--ao=null', '--keep-open=no',
    '-v', '-v', '--msg-level=all=v,ffmpeg=trace',
    "--log-file=$log",
    "--script=$(Join-Path $here '03-seek.lua')",
    "--audio-file=$audio"
  )
  if ($c.o) { $mpvArgs += "--stream-lavf-o=$($c.o)" }
  $mpvArgs += $video

  $p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
  $p.WaitForExit()

  $text = Get-Content $log -Raw -ErrorAction SilentlyContinue

  # The Range header ffmpeg actually put on the first request to the video URL.
  $ranges = [regex]::Matches($text, 'Range: bytes=([0-9]+)-([0-9]*)') |
            ForEach-Object { "bytes=$($_.Groups[1].Value)-$($_.Groups[2].Value)" } |
            Select-Object -First 3
  $codes   = [regex]::Matches($text, "header='HTTP/1\.1 (\d{3})") |
             ForEach-Object { $_.Groups[1].Value } | Select-Object -First 4
  $verdict = ([regex]::Match($text, 'SPIKE VERDICT[^\r\n]*')).Value
  $optbad  = if ($text -match 'Option .*not found|Error setting option') { 'OPTION REJECTED' } else { '' }

  $tone = if ($verdict -match 'seek_ok=true') { 'Green' }
          elseif ($verdict -match 'played=true') { 'Yellow' } else { 'Red' }
  Write-Host ("{0,-32} first-ranges=[{1}] codes=[{2}] {3}" -f `
    $c.n, ($ranges -join ' '), ($codes -join ','), $optbad) -ForegroundColor $tone
  if ($verdict) { Write-Host "    $verdict" -ForegroundColor DarkGray }
  else { Write-Host "    (no verdict - playback never started)" -ForegroundColor DarkGray }
}
