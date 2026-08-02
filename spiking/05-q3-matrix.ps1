# Spike 05 Q3 — seek matrix across DLLs, codecs and request_size on/off.
#
# Control rows matter more than the headline: the shipped 2023 DLL *accepts*
# stream-lavf-o=request_size without error and then ignores it, which is the
# silent-failure shape CLAUDE.md warns about.

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$out  = Join-Path $here '05-out'
$sp   = 'C:\Users\LordLux\AppData\Local\Temp\claude\C--Projects-NativeYouTube\147f1e6a-a591-4391-a49a-f7f62afafb1c\scratchpad\05'

$shipped   = Join-Path $sp 'mpv-dev-x86_64-20230924-git-652a1dd\libmpv-2.dll'
$mainpin   = Join-Path $sp 'mpv-dev-x86_64-20241021-git-0f78584\libmpv-2.dll'
$candidate = Join-Path $sp 'mpv-dev-x86_64-20260610-git-304426c\libmpv-2.dll'

$cases = @(
  @{ n = 'candidate  av1  request_size'; d = $candidate; t = 'av1'; m = 'request_size' },
  @{ n = 'candidate  av1  baseline';     d = $candidate; t = 'av1'; m = 'baseline' },
  @{ n = 'candidate  vp9  request_size'; d = $candidate; t = 'vp9'; m = 'request_size' },
  @{ n = 'shipped    av1  request_size'; d = $shipped;   t = 'av1'; m = 'request_size' },
  @{ n = 'main-pin   av1  request_size'; d = $mainpin;   t = 'av1'; m = 'request_size' }
)

$summary = @()
foreach ($c in $cases) {
  $slug = ($c.n -replace '[^a-zA-Z0-9]+', '-').Trim('-').ToLower()
  $json = Join-Path $out "q3-$slug.json"
  $err  = Join-Path $out "q3-$slug.err"

  Write-Host "running $($c.n) ..." -ForegroundColor Cyan
  $p = Start-Process -FilePath 'python' `
        -ArgumentList @('05-q3-seek.py', $c.d, (Join-Path $out 'urls.json'), $c.t, $c.m) `
        -WorkingDirectory $here -NoNewWindow -PassThru `
        -RedirectStandardOutput $json -RedirectStandardError $err
  $p.WaitForExit()

  if ($p.ExitCode -ne 0) {
    Write-Host ("  {0,-32} CRASHED exit={1}" -f $c.n, $p.ExitCode) -ForegroundColor Red
    $summary += [pscustomobject]@{ case = $c.n; result = "crashed($($p.ExitCode))" }
    Get-Content $err -Tail 5 | ForEach-Object { Write-Host "      $_" -ForegroundColor DarkGray }
    continue
  }

  $v = Get-Content $json -Raw | ConvertFrom-Json
  $tone = if ($v.seeks_ok -eq 4) { 'Green' } elseif ($v.seeks_ok -eq 0) { 'Red' } else { 'Yellow' }
  Write-Host ("  {0,-32} seeks={1}/4 played={2} hwdec={3} a={4} cpu={5}s" -f `
      $c.n, $v.seeks_ok, $v.played, $v.hwdec_current, $v.audio_codec, $v.cpu_seconds) -ForegroundColor $tone
  $summary += [pscustomobject]@{
    case = $c.n; mpv = $v.mpv_version; ffmpeg = $v.ffmpeg_version
    seeks = "$($v.seeks_ok)/4"; played = $v.played; hwdec = $v.hwdec_current
    audio = $v.audio_codec; cpu = $v.cpu_seconds; drops = $v.frame_drop_count
  }
}

$summary | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $out 'q3-matrix.json') -Encoding utf8
$summary | Format-Table -AutoSize
