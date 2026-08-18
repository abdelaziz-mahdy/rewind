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

/// What one PE image needs at load time: the lower-cased DLL names, plus the
/// function names it imports from each (delay-imports contribute names only,
/// since the loader resolves those lazily and a missing one cannot stop the
/// process from starting).
class PeNeeds {
  final Set<String> dlls = {};
  final Map<String, Set<String>> symbols = {}; // dll -> imported function names
}

/// Parses the import + delay-import directories of a PE image.
PeNeeds peImports(File file) {
  final d = file.readAsBytesSync();
  final b = ByteData.sublistView(d);
  if (d.length < 0x40 || d[0] != 0x4d || d[1] != 0x5a) {
    return PeNeeds(); // not "MZ"
  }
  final pe = b.getUint32(0x3c, Endian.little);
  if (pe + 24 > d.length ||
      d[pe] != 0x50 ||
      d[pe + 1] != 0x45 ||
      d[pe + 2] != 0 ||
      d[pe + 3] != 0) {
    return PeNeeds(); // not "PE\0\0"
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

  /// Walks an Import Name Table: 8-byte thunks (PE32+; 4-byte for PE32),
  /// each either an ordinal (high bit set — no name to check) or an RVA to a
  /// 2-byte hint followed by the function name.
  Set<String> thunkNames(int intRva) {
    final names = <String>{};
    if (intRva == 0) return names;
    var t = offsetOf(intRva);
    if (t == null) return names;
    final wide = magic == 0x20b;
    final step = wide ? 8 : 4;
    while (t! + step <= d.length) {
      final value =
          wide ? b.getUint64(t, Endian.little) : b.getUint32(t, Endian.little);
      if (value == 0) break;
      final isOrdinal =
          wide ? (value & 0x8000000000000000) != 0 : (value & 0x80000000) != 0;
      if (!isOrdinal) {
        // +2 skips the hint; the name follows, NUL-terminated. Exported
        // symbol names are case-sensitive on Windows, unlike file names.
        final o = offsetOf(value & 0x7fffffff);
        if (o != null && o + 2 < d.length) {
          var end = o + 2;
          while (end < d.length && d[end] != 0) {
            end++;
          }
          names.add(String.fromCharCodes(d.sublist(o + 2, end)));
        }
      }
      t += step;
    }
    return names;
  }

  final needs = PeNeeds();
  // Directory 1 = imports: 20-byte descriptors, DLL name at +12, Import Name
  // Table at +0 (falling back to the IAT at +16, which holds the same thunks
  // before the loader overwrites them).
  final impDir = dirs + 8;
  if (impDir + 8 <= d.length) {
    final rva = b.getUint32(impDir, Endian.little);
    var o = rva == 0 ? null : offsetOf(rva);
    while (o != null && o + 20 <= d.length) {
      if (d.sublist(o, o + 20).every((byte) => byte == 0)) break;
      final nameRva = b.getUint32(o + 12, Endian.little);
      if (nameRva == 0) break;
      final dll = nameAt(nameRva);
      if (dll == null) break;
      needs.dlls.add(dll);
      var intRva = b.getUint32(o, Endian.little);
      if (intRva == 0) intRva = b.getUint32(o + 16, Endian.little);
      (needs.symbols[dll] ??= <String>{}).addAll(thunkNames(intRva));
      o += 20;
    }
  }
  // Directory 13 = delay imports: 32-byte descriptors, DLL name at +4. Names
  // only — the loader resolves these on first call, so a missing one is a
  // runtime error in one code path, not a failure to start.
  final delayDir = dirs + 8 * 13;
  if (delayDir + 8 <= d.length) {
    final rva = b.getUint32(delayDir, Endian.little);
    var o = rva == 0 ? null : offsetOf(rva);
    while (o != null && o + 32 <= d.length) {
      if (d.sublist(o, o + 32).every((byte) => byte == 0)) break;
      final nameRva = b.getUint32(o + 4, Endian.little);
      if (nameRva == 0) break;
      final dll = nameAt(nameRva);
      if (dll == null) break;
      needs.dlls.add(dll);
      o += 32;
    }
  }
  return needs;
}

/// The function names a PE image exports by name (ordinal-only exports are
/// not relevant here: an import that names a function needs a named export).
Set<String> peExports(File file) {
  final d = file.readAsBytesSync();
  final b = ByteData.sublistView(d);
  if (d.length < 0x40 || d[0] != 0x4d || d[1] != 0x5a) return {};
  final pe = b.getUint32(0x3c, Endian.little);
  if (pe + 24 > d.length || d[pe] != 0x50 || d[pe + 1] != 0x45) return {};
  final numSections = b.getUint16(pe + 6, Endian.little);
  final optHeaderSize = b.getUint16(pe + 20, Endian.little);
  final opt = pe + 24;
  final magic = b.getUint16(opt, Endian.little);
  final dirs = opt + (magic == 0x20b ? 112 : 96);

  final sections = <List<int>>[];
  final secStart = opt + optHeaderSize;
  for (var i = 0; i < numSections; i++) {
    final s = secStart + 40 * i;
    if (s + 40 > d.length) break;
    final virtualSize = b.getUint32(s + 8, Endian.little);
    final virtualAddr = b.getUint32(s + 12, Endian.little);
    final rawSize = b.getUint32(s + 16, Endian.little);
    final rawPtr = b.getUint32(s + 20, Endian.little);
    sections.add(
        [virtualAddr, virtualSize > rawSize ? virtualSize : rawSize, rawPtr]);
  }
  int? offsetOf(int rva) {
    for (final s in sections) {
      if (rva >= s[0] && rva < s[0] + s[1]) return s[2] + (rva - s[0]);
    }
    return null;
  }

  final exports = <String>{};
  if (dirs + 8 > d.length) return exports;
  final tableRva = b.getUint32(dirs, Endian.little);
  if (tableRva == 0) return exports;
  final table = offsetOf(tableRva);
  if (table == null || table + 40 > d.length) return exports;
  final count = b.getUint32(table + 24, Endian.little); // NumberOfNames
  final namesRva = b.getUint32(table + 32, Endian.little); // AddressOfNames
  final names = offsetOf(namesRva);
  if (names == null) return exports;
  for (var i = 0; i < count; i++) {
    final entry = names + 4 * i;
    if (entry + 4 > d.length) break;
    final o = offsetOf(b.getUint32(entry, Endian.little));
    if (o == null || o >= d.length) continue;
    var end = o;
    while (end < d.length && d[end] != 0) {
      end++;
    }
    exports.add(String.fromCharCodes(d.sublist(o, end)));
  }
  return exports;
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

  final byName = {
    for (final f in files) f.uri.pathSegments.last.toLowerCase(): f,
  };
  final exportsOf = <String, Set<String>>{}; // bundled dll -> exported names

  final missing = <String, Set<String>>{}; // dll -> importers
  // "dll!function" -> importers. A DLL that IS present but does not export
  // something an importer asks for fails the load with ERROR_PROC_NOT_FOUND
  // (127) — the same "app dies before it starts" outcome as a missing file,
  // and just as invisible to a build-only CI job.
  final unresolved = <String, Set<String>>{};

  for (final f in files) {
    final importer = f.uri.pathSegments.last;
    final needs = peImports(f);
    for (final need in needs.dlls) {
      if (_isApiSet(need) || _optionalDlls.contains(need)) continue;
      if (_isDebugRuntime(need)) continue;
      if (_isRedistributable(need)) {
        if (present.contains(need)) continue;
      } else if (present.contains(need) || _systemDlls.contains(need)) {
        // Symbol-level check, for bundled DLLs only: Windows' own exports
        // are not ours to verify, and reading System32 would make the result
        // depend on the machine running the check.
        final provider = byName[need];
        if (provider != null) {
          final exports = exportsOf[need] ??= peExports(provider);
          // A DLL with no named exports at all is either a resource-only
          // module or one built without export annotations; either way,
          // reporting each symbol separately would bury the real message.
          for (final symbol in needs.symbols[need] ?? const <String>{}) {
            if (!exports.contains(symbol)) {
              (unresolved['$need!$symbol'] ??= <String>{}).add(importer);
            }
          }
        }
        continue;
      }
      (missing[need] ??= <String>{}).add(importer);
    }
  }

  print('Checked ${files.length} binaries in ${dir.path}');
  if (missing.isEmpty && unresolved.isEmpty) {
    print('OK: every imported DLL is bundled or part of Windows, and every '
        'imported symbol resolves.');
    return;
  }
  if (missing.isNotEmpty) {
    stderr.writeln('MISSING dependencies — this bundle will fail to launch on '
        'a clean Windows machine:');
    final names = missing.keys.toList()..sort();
    for (final name in names) {
      final importers = (missing[name]!.toList()..sort()).join(', ');
      final note = _isRedistributable(name)
          ? '  (Visual C++ redistributable — must ship app-local)'
          : '';
      stderr.writeln('  $name$note\n      imported by: $importers');
    }
  }
  if (unresolved.isNotEmpty) {
    stderr.writeln('UNRESOLVED imports — the DLL is present but does not '
        'export what is asked of it (load fails with error 127):');
    final names = unresolved.keys.toList()..sort();
    for (final name in names.take(40)) {
      final importers = (unresolved[name]!.toList()..sort()).join(', ');
      stderr.writeln('  $name\n      imported by: $importers');
    }
    if (names.length > 40) {
      stderr.writeln('  ... and ${names.length - 40} more');
    }
  }
  exit(1);
}
