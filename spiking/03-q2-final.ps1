# Spike 03 / Q2 check 4, final - repeated seeks, both codecs, real video output.
#
# The matrix used --vo=null to keep the runs headless, which forces hwdec into
# copy-back mode and is not what playback actually looks like. This run uses
# --vo=gpu so the hardware-decode answer is the one the app would get, and seeks
# four times (forward, backward, forward, backward) rather than once.
#
# Resolves fresh, because a URL captured an hour ago proves nothing about the one
# the app will hand mpv.

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '03-out'
$RS   = 1048576

Write-Host "resolving ANDROID_VR fresh..." -ForegroundColor Cyan
$rp = Start-Process -FilePath 'node' -ArgumentList @('03-q2-http.mjs','aqz-KE-bpKQ') `
      -WorkingDirectory $here -NoNewWindow -PassThru `
      -RedirectStandardOutput (Join-Path $out 'q2-final-resolve.log') `
      -RedirectStandardError  (Join-Path $out 'q2-final-resolve.err')
$rp.WaitForExit()
$vr = Get-Content (Join-Path $out 'q2-urls.json') -Raw | ConvertFrom-Json

$cases = @(
  @{ n = 'AV1 401  baseline';     f = $vr.av1; o = $null },
  @{ n = 'AV1 401  request_size'; f = $vr.av1; o = "request_size=$RS,short_seek_size=$RS" },
  @{ n = 'VP9 315  request_size'; f = $vr.vp9; o = "request_size=$RS,short_seek_size=$RS" }
)

foreach ($c in $cases) {
  $slug = ($c.n -replace '[^a-zA-Z0-9]+','-').Trim('-').ToLower()
  $log  = Join-Path $out "q2-final-$slug.log"

  $mpvArgs = @(
    '--no-config','--hwdec=auto','--vo=gpu','--force-window=yes','--keep-open=no',
    '--msg-level=all=info,vd=v',
    "--script=$(Join-Path $here '03-seek-multi.lua')",
    "--audio-file=$($vr.audio.url)"
  )
  if ($c.o) { $mpvArgs += "--stream-lavf-o=$($c.o)" }
  $mpvArgs += $c.f.url

  $p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
        -RedirectStandardOutput $log -RedirectStandardError "$log.err"
  $p.WaitForExit()
  $cpu = $p.TotalProcessorTime.TotalSeconds

  $text = (Get-Content $log -Raw -ErrorAction SilentlyContinue) + "`n" +
          (Get-Content "$log.err" -Raw -ErrorAction SilentlyContinue)
  $verdict = ([regex]::Match($text, 'SPIKE VERDICT[^\r\n]*')).Value
  $hw = ([regex]::Match($text, 'Using (hardware|software) decoding[^\r\n]*')).Value

  $tone = if ($verdict -match 'seeks_ok=4/4') { 'Green' }
          elseif ($verdict -match 'seeks_ok=0/4') { 'Red' } else { 'Yellow' }
  Write-Host ("{0,-22} cpu={1,5:N1}s  {2}" -f $c.n, $cpu, $hw) -ForegroundColor $tone
  Write-Host "    $verdict" -ForegroundColor DarkGray
  ($text -split "`n" | Where-Object { $_ -match 'SPIKE seek \d (OK|STALLED)' }) |
    ForEach-Object { Write-Host "      $($_.Trim())" -ForegroundColor DarkGray }
}
