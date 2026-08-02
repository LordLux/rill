# Spike 03 / Q2 check 4, second pass — why does the seek fail?
#
# The first pass showed mpv playing an ANDROID_VR URL and then failing every
# seek, including a short forward one, while the same URL answered
# `Range: bytes=<off>-` with 206 from a plain HTTP client. So the refusal is not
# where F10 predicted. This turns ffmpeg's protocol logging all the way up to see
# the actual request it makes on reposition.

param([string]$Which = 'av1')

$ErrorActionPreference = 'Stop'
$mpv  = 'C:\Program Files\MPV Player\mpv.exe'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$urls = Get-Content (Join-Path $here '03-out\q2-urls.json') -Raw | ConvertFrom-Json
$fmt  = $urls.$Which

$log = Join-Path $here "03-out\q2-mpv-trace-$Which.log"

$mpvArgs = @(
  '--no-config',
  '--hwdec=auto',
  '--vo=null',
  '--ao=null',
  '--keep-open=no',
  '-v', '-v',
  '--msg-level=all=v,ffmpeg=trace,stream=trace,cache=v',
  "--log-file=$log",
  "--script=$(Join-Path $here '03-seek.lua')",
  "--audio-file=$($urls.audio.url)",
  $fmt.url
)

Write-Host "tracing $Which itag $($fmt.itag) ..." -ForegroundColor Cyan
$p = Start-Process -FilePath $mpv -ArgumentList $mpvArgs -NoNewWindow -PassThru `
      -RedirectStandardOutput "$log.stdout" -RedirectStandardError "$log.stderr"
$p.WaitForExit()
Write-Host "exit=$($p.ExitCode)  log=$log  ($((Get-Item $log).Length) bytes)"
