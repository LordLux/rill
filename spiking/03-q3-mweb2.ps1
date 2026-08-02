# Spike 03 / Q3 follow-up - is MWEB's 403 about the request shape or the pace?
#
# With request_size=1M, MWEB stopped failing at open and streamed ~128 MB of
# bounded 206s before a 403 killed it. mpv fills its readahead cache as fast as
# the server will serve, which was ~17 MB/s here - far above the ~2x realtime
# pacing an open-ended request gets. Task 02 saw the same shape: bounded requests
# fine up to a point, "the boundary shifted as requests accumulated".
#
# So: same option, but hold mpv's readahead down. If MWEB survives, the ceiling
# is about pace and MWEB is arguably usable; if it 403s anyway, request_size only
# moves where the failure happens.

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '03-out'

$probe = Get-Content (Join-Path $out 'q3-probe.log') -Raw
$m = [regex]::Match($probe, 'mpv "([^"]+)" --audio-file="([^"]+)"')
$video = $m.Groups[1].Value
$audio = $m.Groups[2].Value

$RS = 1048576
$cases = @(
  @{ n = 'default readahead'; extra = @() },
  @{ n = 'readahead 32MiB';   extra = @('--demuxer-max-bytes=32MiB','--demuxer-readahead-secs=20') },
  @{ n = 'readahead 8MiB';    extra = @('--demuxer-max-bytes=8MiB','--demuxer-readahead-secs=5') },
  @{ n = 'cache off';         extra = @('--cache=no','--demuxer-max-bytes=8MiB') }
)

foreach ($c in $cases) {
  $slug = ($c.n -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLower()
  $log  = Join-Path $out "q3-mweb2-$slug.log"

  $mpvArgs = @(
    '--no-config','--hwdec=auto','--vo=null','--ao=null','--keep-open=no',
    '-v','-v','--msg-level=all=v,ffmpeg=trace',
    "--log-file=$log",
    "--stream-lavf-o=request_size=$RS,short_seek_size=$RS",
    "--script=$(Join-Path $here '03-seek.lua')",
    "--audio-file=$audio"
  ) + $c.extra + @($video)

  $p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput "$log.out" -RedirectStandardError "$log.err"
  $p.WaitForExit()

  $text = Get-Content $log -Raw -ErrorAction SilentlyContinue
  $codes = [regex]::Matches($text, "header='HTTP/1\.1 (\d{3})")
  $n206 = ($codes | Where-Object { $_.Groups[1].Value -eq '206' }).Count
  $n403 = ($codes | Where-Object { $_.Groups[1].Value -eq '403' }).Count

  # How far into the file did it get before the first fatal 403?
  $lastRange = ([regex]::Matches($text, 'Range: bytes=(\d+)-') |
                ForEach-Object { [int64]$_.Groups[1].Value } | Measure-Object -Maximum).Maximum
  $verdict = ([regex]::Match($text, 'SPIKE VERDICT[^\r\n]*')).Value
  $wall = ([regex]::Matches($text, '^\[\s*([\d.]+)\]') | Select-Object -Last 1)
  $lastT = if ($wall) { $wall.Groups[1].Value } else { '?' }

  $tone = if ($verdict -match 'seek_ok=true') { 'Green' }
          elseif ($verdict -match 'played=true') { 'Yellow' } else { 'Red' }
  Write-Host ("{0,-20} 206={1,-4} 403={2,-3} furthest={3,10:N0} B  survived={4}s" -f `
    $c.n, $n206, $n403, $lastRange, $lastT) -ForegroundColor $tone
  if ($verdict) { Write-Host "    $verdict" -ForegroundColor DarkGray }
  else { Write-Host "    (died before the 24s verdict)" -ForegroundColor DarkGray }
}
