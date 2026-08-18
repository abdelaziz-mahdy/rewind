#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Bundles the fetched libobs Windows SDK (native/third_party/obs/, see
  tools/fetch_libobs_windows.ps1) next to a built rewind.exe so it's a
  self-contained, relocatable package that doesn't depend on the source
  tree at runtime.

.PARAMETER BuildDir
  Path to the Flutter Windows runner output directory that contains
  rewind.exe, e.g.
    tools/bundle_obs_windows.ps1 build/windows/x64/runner/Debug
    tools/bundle_obs_windows.ps1 build/windows/x64/runner/Release

.DESCRIPTION
  Layout produced (all paths relative to BuildDir), matching exactly what
  native/shim/rewind_obs.c's Windows setup_module_paths()/
  find_graphics_module_path()/find_obs_sdk_dir() expect at runtime (see
  native/shim/README.md's Windows section for the full trace):

    rewind.exe
    rewind_obs.dll                  (already there — the compiled shim)
    obs.dll, libobs-d3d11.dll, libobs-opengl.dll, libobs-winrt.dll,
    w32-pthreads.dll, obs-ffmpeg-mux.exe, obs-{nvenc,qsv,amf}-test.exe,
    av{codec,format,util,filter,device}-*.dll, swscale-*.dll,
    swresample-*.dll, libx264-*.dll, librist.dll, srt.dll, libcurl.dll,
    zlib.dll                        <- FLAT, straight from the SDK's
                                        bin/64bit/ (find_graphics_module_path's
                                        packaged-layout candidate looks for
                                        libobs-d3d11.dll directly beside the
                                        shim DLL, no bin/64bit nesting)
    obs-plugins/64bit/*.dll         <- nested, from the SDK's
                                        obs-plugins/64bit/ (setup_module_paths'
                                        bin template is
                                        "<sdk>/obs-plugins/64bit/%module%.dll")
    data/libobs/*                  <- nested (obs_add_data_path target)
    data/obs-plugins/<name>/*      <- nested (setup_module_paths' data
                                        template)

  Idempotent: safe to re-run against the same BuildDir (overwrites prior
  copies).

.NOTES
  Windows only (this manipulates a Windows build output; also relies on
  Copy-Item semantics that assume a Windows filesystem for the flat
  bin/64bit -> BuildDir copy). Run after `flutter build windows` — an MSBuild
  post-build step wiring this in automatically is a possible follow-up (see
  ROADMAP.md); for now it's invoked explicitly, same as CI does.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$BuildDir
)

$ErrorActionPreference = 'Stop'

$RepoRoot = Resolve-Path (Join-Path $PSScriptRoot '..')
$SdkDir = Join-Path $RepoRoot 'native/third_party/obs'

if (-not (Test-Path $BuildDir)) {
    Write-Error "build directory not found: $BuildDir"
    exit 1
}
$BuildDir = (Resolve-Path $BuildDir).Path

if (-not (Test-Path (Join-Path $SdkDir 'obs-plugins'))) {
    Write-Error "libobs SDK not found at $SdkDir (run tools/fetch_libobs_windows.ps1 first)"
    exit 1
}

# The flat copy below OVERWRITES same-named files Flutter already installed.
# That matters because libobs ships its own FFmpeg (avcodec-61.dll and
# friends) and so does ffmpeg_kit_flutter_new — the same file names, built
# by different toolchains (MSVC vs MinGW, the latter additionally rebased
# with ASLR off by the plugin's own build step). Whichever copy lands last
# is the one BOTH consumers get. Report every such collision rather than
# resolving it silently: if thumbnail generation or capture starts failing
# on Windows, this list is the first place to look.
Write-Host "==> Copying libobs runtime (bin/64bit/*, flat) into $BuildDir"
$collisions = @()
Get-ChildItem -Path (Join-Path $SdkDir 'bin/64bit') -File | ForEach-Object {
    $dest = Join-Path $BuildDir $_.Name
    if (Test-Path $dest) {
        $existing = (Get-FileHash $dest -Algorithm SHA256).Hash
        $incoming = (Get-FileHash $_.FullName -Algorithm SHA256).Hash
        if ($existing -ne $incoming) { $collisions += $_.Name }
    }
    Copy-Item $_.FullName $dest -Force
}
if ($collisions.Count -gt 0) {
    Write-Warning ("libobs overwrote $($collisions.Count) differing file(s) " +
        "already in the build: " + ($collisions -join ', '))
}

Write-Host "==> Copying obs-plugins/64bit/ into $BuildDir\obs-plugins\64bit"
$pluginsDest = Join-Path $BuildDir 'obs-plugins/64bit'
if (Test-Path $pluginsDest) { Remove-Item -Recurse -Force $pluginsDest }
New-Item -ItemType Directory -Force -Path $pluginsDest | Out-Null
Copy-Item (Join-Path $SdkDir 'obs-plugins/64bit/*') $pluginsDest -Recurse -Force

# MERGE into data\, never replace it. Flutter's own runtime lives in the
# SAME directory — data\icudtl.dat, data\flutter_assets\, data\app.so —
# and libobs wants its files at <exe>\data\libobs\ (see
# rw_plat_pre_video_setup's obs_add_data_path call). Deleting data\ before
# copying therefore removed the Flutter engine's assets: v0.1.0 shipped with
# no flutter_assets and no icudtl.dat, so rewind.exe exited immediately on
# every machine. Clear only the subdirectories libobs owns, so a stale
# plugin data file cannot survive a re-bundle either.
Write-Host "==> Merging data/ into $BuildDir\data (Flutter's own data lives here too)"
$dataDest = Join-Path $BuildDir 'data'
New-Item -ItemType Directory -Force -Path $dataDest | Out-Null
foreach ($owned in @('libobs', 'obs-plugins')) {
    $dir = Join-Path $dataDest $owned
    if (Test-Path $dir) { Remove-Item -Recurse -Force $dir }
}
Copy-Item (Join-Path $SdkDir 'data/*') $dataDest -Recurse -Force

# Flutter's engine data must have survived the merge: without icudtl.dat or
# flutter_assets the app exits during engine startup, before any Dart runs.
foreach ($required in @('icudtl.dat', 'flutter_assets')) {
    if (-not (Test-Path (Join-Path $dataDest $required))) {
        Write-Error "data\$required missing from $BuildDir after bundling — the Flutter engine's own data was clobbered"
        exit 1
    }
}

# obs-ffmpeg-mux.exe was already copied by the flat bin/64bit/* loop above
# (it lives there, same as the macOS bundle script's equivalent helper
# copy) — sanity-check it landed, since a missing helper turns into a
# late, confusing "Failed to create process pipe" failure at save time
# (see rewind_obs.c's mux_helper_present()).
$muxHelper = Join-Path $BuildDir 'obs-ffmpeg-mux.exe'
if (-not (Test-Path $muxHelper)) {
    Write-Error "obs-ffmpeg-mux.exe missing from $BuildDir after bundling — re-run tools/fetch_libobs_windows.ps1"
    exit 1
}

Write-Host "==> Done. libobs runtime bundled into $BuildDir"
