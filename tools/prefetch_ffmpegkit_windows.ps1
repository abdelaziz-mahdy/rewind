# Prefetch the FFmpegKit Windows bundle into a real (non-symlinked) directory
# and expose it via FFMPEGKIT_LOCAL_DIR, so ffmpeg_kit_flutter_new's Windows
# CMake COPIES it instead of `tar xf`-ing through Flutter's plugin symlink
# (which CMake's libarchive refuses — "Cannot extract through symlink").
#
# The version/variant/arch here MUST match ffmpeg_kit_flutter_new's
# windows/CMakeLists.txt defaults (FFMPEGKIT_VERSION / FFMPEGKIT_PACKAGE /
# FFMPEGKIT_ARCH). Update these when bumping the ffmpeg_kit_flutter_new pin.
$ErrorActionPreference = "Stop"

$version = "8.1.2"
$package = "full-gpl"
$arch    = "x86_64"

$zipName = "ffmpeg-kit-windows-$arch-$package-$version.zip"
$url = "https://github.com/sk3llo/ffmpeg_kit_flutter/releases/download/$version-$package/$zipName"

$dir = Join-Path $env:RUNNER_TEMP "ffmpegkit"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
$zip = Join-Path $dir $zipName

Write-Host "Downloading $url"
Invoke-WebRequest -Uri $url -OutFile $zip
Write-Host "Extracting to $dir"
Expand-Archive -Path $zip -DestinationPath $dir -Force

# The bundle root is the directory that holds bin/libffmpegkit.dll — usually
# $dir itself, but tolerate a wrapping folder inside the zip.
$binDll = Get-ChildItem -Path $dir -Recurse -File -Filter "libffmpegkit.dll" |
  Where-Object { $_.Directory.Name -eq "bin" } | Select-Object -First 1
if (-not $binDll) {
  throw "libffmpegkit.dll not found under a bin/ in the extracted bundle ($dir)"
}
$local = Split-Path (Split-Path $binDll.FullName -Parent) -Parent

Write-Host "FFMPEGKIT_LOCAL_DIR=$local"
"FFMPEGKIT_LOCAL_DIR=$local" | Out-File -FilePath $env:GITHUB_ENV -Append -Encoding utf8
