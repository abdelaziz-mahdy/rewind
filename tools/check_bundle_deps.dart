// Verifies a built Windows bundle can actually LOAD: every DLL its binaries
// import must either sit in the bundle or be a Windows system DLL.
//
// Why this exists: v0.1.0 shipped a rewind.exe importing MSVCP140.dll /
// VCRUNTIME140.dll / VCRUNTIME140_1.dll — the Visual C++ redistributable,
// which is NOT part of a clean Windows install and which nothing in the
// packaging shipped. The Windows loader resolves imports BEFORE any code
// runs, so on a machine without the redist the process died with
// 0xc0000135 before the Flutter engine started: no window, no crash dialog
// worth the name, and — the reason this was so hard to see — no log file at
// all, since `startFileLogging` is Dart code that never got to run.
//
// A launch smoke test does NOT catch this: GitHub's windows runners have
// the redist preinstalled (Visual Studio puts it there), so the app starts
// fine in CI and only users on clean machines crash. Hence a STATIC check:
// the redistributable runtime DLLs are deliberately treated as "must be in
// the bundle" even though they exist in System32 on every build machine.
//
// Usage:
//   dart run tools/check_bundle_deps.dart build/windows/x64/runner/Release
//
// Exits non-zero (and lists the offenders) when something is missing.
import 'dart:io';
import 'dart:typed_data';

/// Windows system DLLs — shipped with the OS, resolved from System32, and
/// never packaged with an app. Anything imported and NOT in this set must be
/// in the bundle. Kept explicit rather than probing System32 so the check is
/// identical on every host (and so a redist DLL that happens to be installed
/// on the build machine cannot mask a missing one).
const _systemDlls = {
  'advapi32.dll',
  'avicap32.dll',
  'avrt.dll',
  'bcrypt.dll',
  'bcryptprimitives.dll',
  'cfgmgr32.dll',
  'combase.dll',
  'comctl32.dll',
  'comdlg32.dll',
  'coremessaging.dll',
  'crypt32.dll',
  'd3d9.dll',
  'd3d11.dll',
  'd3d12.dll',
  'dbghelp.dll',
  'dcomp.dll',
  'dnsapi.dll',
  'dsound.dll',
  'dwmapi.dll',
  'dxgi.dll',
  'dxva2.dll',
  'gdi32.dll',
  'gdiplus.dll',
  'imm32.dll',
  'iphlpapi.dll',
  'kernel32.dll',
  'kernelbase.dll',
  'mf.dll',
  'mfplat.dll',
  'mfreadwrite.dll',
  'mfuuid.dll',
  'msimg32.dll',
  'msvcrt.dll',
  'mswsock.dll',
  'wsock32.dll',
  'ncrypt.dll',
  'netapi32.dll',
  'normaliz.dll',
  'ntdll.dll',
  'ole32.dll',
  'oleacc.dll',
  'oleaut32.dll',
  'opengl32.dll',
  'pdh.dll',
  'powrprof.dll',
  'propsys.dll',
  'psapi.dll',
  'rpcrt4.dll',
  'secur32.dll',
  'setupapi.dll',
  'shcore.dll',
  'shell32.dll',
  'shlwapi.dll',
  'user32.dll',
  'userenv.dll',
  'usp10.dll',
  'uiautomationcore.dll',
  'uxtheme.dll',
  'version.dll',
  'wer.dll',
  'windowscodecs.dll',
  'winhttp.dll',
  'wininet.dll',
  'winmm.dll',
  'winspool.drv',
  'wintrust.dll',
  'wldap32.dll',
  'ws2_32.dll',
  'wtsapi32.dll',
  'ucrtbase.dll',
  'dwrite.dll',
  'd3dcompiler_47.dll',
};

/// The DEBUG C runtime (`vcruntime140d.dll`, `msvcp140d.dll`,
/// `ucrtbased.dll`). Microsoft does not permit redistributing it and
/// `InstallRequiredSystemLibraries` does not offer it, so a debug build is
/// dev-machine-only by construction — flagging it would fail this check on
/// every `flutter build windows --debug` bundle while saying nothing about
/// what ships. Release builds link the redistributable runtime, which IS
/// enforced.
bool _isDebugRuntime(String name) =>
    RegExp(r'^(msvcp|vcruntime|concrt)\d+_?\d*d\.dll$').hasMatch(name) ||
    name == 'ucrtbased.dll';

/// The Visual C++ / MFC redistributable. Present on any machine with Visual
/// Studio (so: every CI runner and every dev box) and absent on a clean
/// Windows — the exact shape of bug that ships green and crashes users. It
/// must be app-local, so a System32 copy never counts.
bool _isRedistributable(String name) =>
    RegExp(r'^(msvcp|vcruntime|concrt|mfc|vcomp)\d').hasMatch(name) ||
    name == 'msvcr120.dll';

/// Imports that are genuinely resolved lazily, so a missing file cannot stop
/// the process from starting. `jvm.dll` is imported by `dartjni.dll`
/// (package:jni, pulled in transitively) and comes from an installed JRE —
/// nothing in Rewind loads dartjni.dll, and the Windows loader only resolves
/// a DLL's own imports when that DLL is loaded.
const _optionalDlls = {'jvm.dll'};

/// True for the OS's own "API set" forwarders (`api-ms-win-*`, `ext-ms-*`),
/// which are never files on disk to begin with.
bool _isApiSet(String name) =>
    name.startsWith('api-ms-') || name.startsWith('ext-ms-');

/// Parses the import + delay-import directories of a PE image, returning the
/// lower-cased DLL names it needs at load time.
Set<String> peImports(File file) {
  final d = file.readAsBytesSync();
  final b = ByteData.sublistView(d);
  if (d.length < 0x40 || d[0] != 0x4d || d[1] != 0x5a) return {}; // not "MZ"
  final pe = b.getUint32(0x3c, Endian.little);
  if (pe + 24 > d.length ||
      d[pe] != 0x50 ||
      d[pe + 1] != 0x45 ||
      d[pe + 2] != 0 ||
      d[pe + 3] != 0) {
    return {}; // not "PE\0\0"
  }
  final numSections = b.getUint16(pe + 6, Endian.little);
  final optHeaderSize = b.getUint16(pe + 20, Endian.little);
  final opt = pe + 24;
  final magic = b.getUint16(opt, Endian.little);
  // Data directories start after the optional header's fixed part: 112 bytes
  // for PE32+ (x64), 96 for PE32.
  final dirs = opt + (magic == 0x20b ? 112 : 96);

  final sections = <List<int>>[]; // [virtualAddress, size, rawPointer]
  final secStart = opt + optHeaderSize;
  for (var i = 0; i < numSections; i++) {
    final s = secStart + 40 * i;
    if (s + 40 > d.length) break;
    final virtualSize = b.getUint32(s + 8, Endian.little);
    final virtualAddr = b.getUint32(s + 12, Endian.little);
    final rawSize = b.getUint32(s + 16, Endian.little);
    final rawPtr = b.getUint32(s + 20, Endian.little);
    sections.add([
      virtualAddr,
      virtualSize > rawSize ? virtualSize : rawSize,
      rawPtr,
    ]);
  }

  int? offsetOf(int rva) {
    for (final s in sections) {
      if (rva >= s[0] && rva < s[0] + s[1]) return s[2] + (rva - s[0]);
    }
    return null;
  }

  String? nameAt(int rva) {
    final o = offsetOf(rva);
    if (o == null || o >= d.length) return null;
    var end = o;
    while (end < d.length && d[end] != 0) {
      end++;
    }
    return String.fromCharCodes(d.sublist(o, end)).toLowerCase();
  }

  final needed = <String>{};
  // Directory 1 = imports (20-byte descriptors, name at +12);
  // directory 13 = delay imports (32-byte descriptors, name at +4).
  for (final (dirIndex, entrySize, nameField) in [(1, 20, 12), (13, 32, 4)]) {
    final dir = dirs + 8 * dirIndex;
    if (dir + 8 > d.length) continue;
    final rva = b.getUint32(dir, Endian.little);
    if (rva == 0) continue;
    var o = offsetOf(rva);
    if (o == null) continue;
    while (o! + entrySize <= d.length) {
      final entry = d.sublist(o, o + entrySize);
      if (entry.every((byte) => byte == 0)) break;
      final nameRva = b.getUint32(o + nameField, Endian.little);
      if (nameRva == 0) break;
      final name = nameAt(nameRva);
      if (name == null) break;
      needed.add(name);
      o += entrySize;
    }
  }
  return needed;
}

void main(List<String> args) {
  if (args.length != 1) {
    stderr.writeln('usage: dart run tools/check_bundle_deps.dart <bundle-dir>');
    exit(2);
  }
  final dir = Directory(args.single);
  if (!dir.existsSync()) {
    stderr.writeln('No such bundle directory: ${dir.path}');
    exit(2);
  }

  final files = dir
      .listSync(recursive: true)
      .whereType<File>()
      .where(
          (f) => RegExp(r'\.(dll|exe)$', caseSensitive: false).hasMatch(f.path))
      .toList();
  if (files.isEmpty) {
    stderr.writeln('No .exe/.dll found under ${dir.path} — wrong directory?');
    exit(2);
  }

  // The loader searches the directory of the running .exe, so a DLL anywhere
  // in the bundle counts as present only by NAME; that matches how libobs'
  // own plugins under obs-plugins\64bit resolve their siblings.
  final present = {
    for (final f in files) f.uri.pathSegments.last.toLowerCase(),
  };

  final missing = <String, Set<String>>{}; // dll -> importers
  for (final f in files) {
    final importer = f.uri.pathSegments.last;
    for (final need in peImports(f)) {
      if (_isApiSet(need) || _optionalDlls.contains(need)) continue;
      if (_isDebugRuntime(need)) continue;
      if (_isRedistributable(need)) {
        if (present.contains(need)) continue;
      } else if (present.contains(need) || _systemDlls.contains(need)) {
        continue;
      }
      (missing[need] ??= <String>{}).add(importer);
    }
  }

  print('Checked ${files.length} binaries in ${dir.path}');
  if (missing.isEmpty) {
    print('OK: every imported DLL is bundled or part of Windows.');
    return;
  }
  stderr.writeln('MISSING dependencies — this bundle will fail to launch on a '
      'clean Windows machine:');
  final names = missing.keys.toList()..sort();
  for (final name in names) {
    final importers = (missing[name]!.toList()..sort()).join(', ');
    final note = _isRedistributable(name)
        ? '  (Visual C++ redistributable — must ship app-local)'
        : '';
    stderr.writeln('  $name$note\n      imported by: $importers');
  }
  exit(1);
}
