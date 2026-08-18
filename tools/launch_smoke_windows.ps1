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

# Give startup a moment past first log line to fall over if it is going to
# (the capture engine comes up after logging does).
Start-Sleep -Seconds 5
if ($proc.HasExited) {
  Write-Host "==> Session log tail:"
  Get-Content $log.FullName -Tail 40
  Write-Error "rewind.exe exited during startup with code $($proc.ExitCode)"
  exit 1
}

Write-Host "==> Started. Session log: $($log.FullName) ($($log.Length) bytes)"
Get-Content $log.FullName -Tail 40
Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
Write-Host "==> OK: the app started and wrote a session log."
