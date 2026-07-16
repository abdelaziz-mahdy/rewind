// Dart build hook: compiles the Rewind C shim (native/shim/rewind_obs.c, plus
// the matching platform backend file when libobs is available — see below)
// into a native "code asset" that Dart/Flutter bundles automatically. This
// removes the need for per-OS build files or manual .dylib/.dll placement —
// the shim ships next to the app and is resolved via the asset id below.
//
// native/shim/ layout (see native/shim/rewind_obs_internal.h for the
// backend-seam design): rewind_obs.c is the shared API layer + no-libobs
// stub, ALWAYS compiled; rewind_obs_macos.c / rewind_obs_windows.c are the
// per-platform libobs backends, each guarded to compile to nothing unless
// both REWIND_USE_LIBOBS is defined AND its own platform matches, and only
// ever added to `sources` below on the matching host platform (so a stub
// build on either OS never even sees the other platform's backend file).
//
// Docs: https://dart.dev/tools/hooks
//
// Mode is picked automatically by whether the libobs SDK has been fetched
// (native/third_party/obs/, gitignored — see tools/fetch_libobs.sh on macOS,
// tools/fetch_libobs_windows.ps1 on Windows):
//
//   - SDK present  -> real libobs mode. Defines REWIND_USE_LIBOBS and adds
//     the SDK's include dir. Linking is per-OS (see below); either way it's
//     the real capture path — see native/shim/README.md.
//   - SDK absent   -> the self-contained stub in rewind_obs.c (#else branch)
//     is compiled instead, so the app still links and runs without the SDK,
//     on every platform.
//
// macOS: libobs ships as a real Apple .framework (not a flat .dylib — see
// tools/fetch_libobs.sh's report), so linking uses `-F<sdk>/lib -framework
// libobs`, not `-lobs`. Two rpaths are set so the built rewind_obs library
// can resolve `@rpath/libobs.framework/...` at load time in both layouts it
// may run from: the SDK's own lib/ (dev-tree `flutter run`/`flutter build
// macos` before bundling) and Contents/Frameworks (the packaged .app, after
// tools/bundle_obs_macos.sh copies the framework there).
//
// Windows: tools/fetch_libobs_windows.ps1 lays out an import library at
// lib/obs.lib (generated from the official prebuilt obs.dll — see that
// script's own header comment for exactly how, since there is no dev SDK
// with headers+import-libs upstream, only a runtime .zip). Linked via the
// typed `libraries`/`libraryDirectories` params (NOT raw `-l`/`-L` flags,
// which are clang/gcc syntax — native_toolchain_c builds with MSVC
// (cl.exe/link.exe) by default on Windows, where library linking is
// `/LIBPATH:<dir>` + `<name>.lib`; `libraries`/`libraryDirectories` are
// this package's cross-toolchain abstraction over that difference, see
// run_cbuilder.dart). Also links the handful of Win32 import libs the
// shim's own Windows code calls into directly (User32 for window/monitor
// enumeration, Dwmapi for the DWM cloaked-window check). No rpath
// equivalent is needed: Windows resolves obs.dll (and everything else
// tools/bundle_obs_windows.ps1 places) via the standard "search the main
// executable's own directory" DLL search rule, since the bundle script
// drops the whole runtime flat next to rewind.exe.
import 'dart:io';

import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final obsRoot =
        Directory.fromUri(input.packageRoot.resolve('native/third_party/obs/'));
    // Same layout check the shim itself uses at runtime (has_sdk_layout in
    // rewind_obs.c) — presence of obs-plugins/ signals a complete fetch, not
    // just an empty/partial directory.
    final useLibobs =
        Directory.fromUri(obsRoot.uri.resolve('obs-plugins/')).existsSync();

    final builder = CBuilder.library(
      name: 'rewind_obs',
      assetName: 'rewind_obs.dart',
      sources: [
        'native/shim/rewind_obs.c',
        if (useLibobs && Platform.isMacOS) 'native/shim/rewind_obs_macos.c',
        if (useLibobs && Platform.isWindows) 'native/shim/rewind_obs_windows.c',
      ],
      includes: [if (useLibobs) 'native/third_party/obs/include'],
      defines: {if (useLibobs) 'REWIND_USE_LIBOBS': null},
      // '.' is CBuilder's own default (CTool.defaultLibraryDirectories,
      // not publicly exported) — kept so this addition doesn't silently
      // drop it for non-Windows/non-libobs builds.
      libraryDirectories: [
        '.',
        if (useLibobs && Platform.isWindows) '${obsRoot.path}/lib',
      ],
      libraries: [
        if (useLibobs && Platform.isWindows) ...['obs', 'user32', 'dwmapi'],
      ],
      flags: [
        if (useLibobs && Platform.isMacOS) ...[
          '-F${obsRoot.path}/lib',
          '-framework', 'libobs',
          '-framework', 'ApplicationServices',
          // Dev-tree runs (flutter run/build before bundling): resolve
          // straight from the fetched SDK via an absolute rpath.
          '-Wl,-rpath,${obsRoot.path}/lib',
          // Packaged app: the Dart/Flutter macOS toolchain wraps this code
          // asset in its own nested rewind_obs.framework bundle rather than
          // placing a flat dylib directly in Contents/Frameworks (confirmed
          // by inspecting an actual `flutter build macos` output — the
          // built binary lands at
          // Contents/Frameworks/rewind_obs.framework/Versions/A/rewind_obs).
          // So @loader_path is that Versions/A directory, three levels
          // below Contents/Frameworks (Versions/A -> Versions ->
          // rewind_obs.framework -> Frameworks) — not one, as a flat
          // layout would need. tools/bundle_obs_macos.sh copies
          // libobs.framework into Contents/Frameworks, so that's the rpath
          // target. Both variants are added since dyld silently skips
          // rpath entries that don't resolve at load time; keeping the
          // flat-layout guess costs nothing and covers a future toolchain
          // change back to flat placement.
          '-Wl,-rpath,@loader_path/../../../',
          '-Wl,-rpath,@loader_path/../Frameworks',
        ],
      ],
    );
    await builder.run(
      input: input,
      output: output,
      logger: null,
    );
  });
}
