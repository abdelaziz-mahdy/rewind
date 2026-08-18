<#
.SYNOPSIS
  Launches a built rewind.exe and fails unless it starts.

.DESCRIPTION
  "It builds" is not "it launches": v0.1.0 shipped a Windows build that died
  in the loader before any of its code ran (a missing Visual C++ runtime),
  and every build-only CI job stayed green.

  This runs the real binary and waits for the session log the app writes
  during startup — the first thing that exists only if Dart got to run. A
  process that exits early, or that never writes a log, fails the step.

  Used instead of integration_test/launch_smoke_test.dart wherever the
  libobs runtime is bundled: `flutter test` rebuilds and re-installs every
  plugin's bundled libraries into the build directory, undoing the bundle
  step (notably putting back a zlib.dll that obs.dll cannot use — see
  tools/bundle_obs_windows.ps1). Launching the built binary directly needs
  no rebuild, so what is tested is what was bundled.

.EXAMPLE
  ./tools/launch_smoke_windows.ps1 build/windows/x64/runner/Release/rewind.exe
#>
param(
  [Parameter(Mandatory = $true)][string]$Exe,
  [int]$TimeoutSeconds = 60
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Exe)) {
  Write-Error "executable not found: $Exe"
  exit 1
}
$Exe = (Resolve-Path $Exe).Path

# path_provider's application-support directory on Windows is
# %APPDATA%\<CompanyName>\<ProductName>, both read from the executable's
# version resource (windows/runner/Runner.rc).
$logs = Join-Path $env:APPDATA 'zcreations/rewind/logs'
if (Test-Path $logs) {
  Remove-Item (Join-Path $logs '*.log') -Force -ErrorAction SilentlyContinue
}

Write-Host "==> Launching $Exe"
$proc = Start-Process $Exe -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$log = $null

while ((Get-Date) -lt $deadline) {
  if ($proc.HasExited) {
    Write-Host "==> Process exited with code $($proc.ExitCode)"
    if ($proc.ExitCode -eq -1073741515) {
      Write-Host "    -1073741515 = 0xC0000135 STATUS_DLL_NOT_FOUND: a DLL the"
      Write-Host "    binary imports is missing. Run tools/check_bundle_deps.dart."
    }
    Write-Error "rewind.exe exited before it finished starting"
    exit 1
  }
  $log = Get-ChildItem $logs -Filter *.log -ErrorAction SilentlyContinue |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1
  if ($log -and $log.Length -gt 0) { break }
  Start-Sleep -Milliseconds 500
}

if (-not $log) {
  Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
  Write-Error "no session log under $logs within ${TimeoutSeconds}s — the app did not start"
  exit 1
}

# Give startup room to finish AND to report. libobs' own messages reach the
# session log through a drain the Dart side polls, so killing the process a
# few seconds in truncates exactly the lines that explain a capture failure.
Start-Sleep -Seconds 20
if ($proc.HasExited) {
  Write-Host "==> Session log tail:"
  Get-Content $log.FullName -Tail 40
  Write-Error "rewind.exe exited during startup with code $($proc.ExitCode)"
  exit 1
}

Write-Host "==> Started. Session log: $($log.FullName) ($($log.Length) bytes)"
$text = Get-Content $log.FullName
$text | ForEach-Object { Write-Host "    $_" }

Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue

# "It started" is not "it works". v0.2.0 shipped with capture completely
# dead — no libobs module loaded, and the display list failed to parse —
# and this step passed anyway, because a process that is alive and logging
# satisfied it. The log says what actually happened; read it.
#
# Two classes, deliberately separated:
#
# FATAL — the build is broken, on any machine. Every one of these means
# libobs' plugins did not load or the shim fed it something it could not
# parse. A source/encoder/output that is "not found" is a TYPE that was
# never registered, which has nothing to do with the hardware present.
$fatal = @(
  '\[exception\]',
  "Source ID '.*' not found",
  "Output ID '.*' not found",
  'Failed to create source',
  'Failed to create output',
  'not registered'
)
# HARDWARE — cannot be judged here. Starting a replay buffer needs a real
# GPU encoder and an audio endpoint; a headless CI VM has neither, so a
# failure to START (as opposed to a missing type above) says nothing about
# the build. Reported loudly, never fatal — the machine running this is not
# the machine that matters for it.
# "Encoder ID ... not found" belongs here, NOT above: the shim asks for
# NVENC first and falls back through AMF, QSV and x264
# (create_video_encoder), so the message is normal on anything without an
# NVIDIA GPU — including every CI runner, which gets Microsoft Basic Render
# Driver. Sources and outputs have no such fallback, so those stay fatal.
$hardware = @(
  'Capture engine failed to start',
  'Replay buffer would not start',
  'Failed to start replay buffer',
  "Encoder ID '.*' not found",
  'NVENC not supported',
  "Failed to initialize module 'obs-nvenc",
  'GetDefaultAudioEndpoint'
)

$hits = $text | Where-Object { $line = $_; $fatal | Where-Object { $line -match $_ } }
$warns = $text | Where-Object { $line = $_; $hardware | Where-Object { $line -match $_ } }

if ($warns) {
  Write-Host "==> Capture did not start (expected on a machine with no GPU/audio):"
  $warns | Select-Object -First 10 | ForEach-Object { Write-Host "    $_" }
}
if ($hits) {
  Write-Host "==> Startup errors in the session log:"
  $hits | Select-Object -First 25 | ForEach-Object { Write-Host "    $_" }
  Write-Error "the app started but libobs did not come up — see the lines above"
  exit 1
}

Write-Host "==> OK: the app started, wrote a session log, and every libobs type it needs is registered."
