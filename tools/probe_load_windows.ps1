<#
.SYNOPSIS
  Asks Windows to load every DLL in a built bundle and reports which ones fail.

.DESCRIPTION
  The static check (tools/check_bundle_deps.dart) proves every imported DLL is
  present and every imported symbol is exported. It cannot prove the loader
  agrees: a dependency resolved from System32 instead of the app directory, an
  architecture mismatch, or a failure deeper in the dependency chain all still
  surface as a bare error code with no module name.

  This asks the loader directly. LoadLibraryEx with LOAD_WITH_ALTERED_SEARCH_PATH
  resolves siblings out of the DLL's own directory, exactly as the app does, and
  the Win32 error for each failure is reported with its meaning:

    126  ERROR_MOD_NOT_FOUND    a dependency file is missing
    127  ERROR_PROC_NOT_FOUND   a dependency is present but lacks an export
    193  ERROR_BAD_EXE_FORMAT   wrong architecture (x86 vs x64)

.EXAMPLE
  ./tools/probe_load_windows.ps1 build/windows/x64/runner/Debug
#>
param(
  [Parameter(Mandatory = $true)][string]$BuildDir,
  # Fail the step when any DLL fails to load. Off by default so the probe can
  # be used purely as a diagnostic next to a check that already gates.
  [switch]$FailOnError
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $BuildDir)) {
  Write-Error "build directory not found: $BuildDir"
  exit 1
}
$BuildDir = (Resolve-Path $BuildDir).Path

Add-Type -Namespace Rewind -Name Loader -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("kernel32", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
public static extern System.IntPtr LoadLibraryEx(string path, System.IntPtr file, uint flags);
'@

# LOAD_WITH_ALTERED_SEARCH_PATH: search the DLL's own directory for its
# dependencies, which is what the app's own load does.
$LOAD_WITH_ALTERED_SEARCH_PATH = 0x8

$meanings = @{
  126 = 'ERROR_MOD_NOT_FOUND (a dependency file is missing)'
  127 = 'ERROR_PROC_NOT_FOUND (a dependency is present but lacks an export)'
  193 = 'ERROR_BAD_EXE_FORMAT (wrong architecture)'
  998 = 'ERROR_NOACCESS'
}

$dlls = Get-ChildItem -Path $BuildDir -Filter *.dll -File -Recurse
Write-Host "==> Probing $($dlls.Count) DLL(s) in $BuildDir"

$failures = @()
foreach ($dll in $dlls) {
  $handle = [Rewind.Loader]::LoadLibraryEx($dll.FullName, [System.IntPtr]::Zero, $LOAD_WITH_ALTERED_SEARCH_PATH)
  if ($handle -eq [System.IntPtr]::Zero) {
    $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
    $why = $meanings[$code]
    if (-not $why) { $why = (New-Object System.ComponentModel.Win32Exception($code)).Message }
    $failures += [pscustomobject]@{ Name = $dll.Name; Code = $code; Why = $why }
  }
}

if ($failures.Count -eq 0) {
  Write-Host "==> OK: every DLL loads."
  exit 0
}

Write-Host "==> $($failures.Count) DLL(s) failed to load:"
foreach ($f in $failures) {
  Write-Host ("    {0}: error {1} — {2}" -f $f.Name, $f.Code, $f.Why)
}
if ($FailOnError) { exit 1 }
exit 0
