// Dart build hook: compiles the Rewind C shim (native/shim/rewind_obs.c) into a
// native "code asset" that Dart/Flutter bundles automatically. This removes the
// need for per-OS build files or manual .dylib/.dll placement — the shim ships
// next to the app and is resolved via the asset id below.
//
// Docs: https://dart.dev/tools/hooks
//
// Mode is picked automatically by whether the libobs SDK has been fetched
// (native/third_party/obs/, gitignored — see tools/fetch_libobs.sh):
//
//   - SDK present  -> real libobs mode. Defines REWIND_USE_LIBOBS, adds the
//     SDK's include dir, and links against lib/libobs.framework (macOS only
//     so far; see native/shim/README.md). libobs ships as a real Apple
//     .framework (not a flat .dylib — see tools/fetch_libobs.sh's report),
//     so linking uses `-F<sdk>/lib -framework libobs`, not `-lobs`.
//     Two rpaths are set so the built rewind_obs library can resolve
//     `@rpath/libobs.framework/...` at load time in both layouts it may run
//     from: the SDK's own lib/ (dev-tree `flutter run`/`flutter build macos`
//     before bundling) and Contents/Frameworks (the packaged .app, after
//     tools/bundle_obs_macos.sh copies the framework there).
//   - SDK absent   -> the self-contained stub in rewind_obs.c (#else branch)
//     is compiled instead, so the app still links and runs without the SDK.
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
      sources: ['native/shim/rewind_obs.c'],
      includes: [if (useLibobs) 'native/third_party/obs/include'],
      defines: {if (useLibobs) 'REWIND_USE_LIBOBS': null},
      flags: [
        if (useLibobs) ...[
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
