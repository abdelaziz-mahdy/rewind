// Dart build hook: compiles the Rewind C shim (native/shim/rewind_obs.c) into a
// native "code asset" that Dart/Flutter bundles automatically. This removes the
// need for per-OS build files or manual .dylib/.dll placement — the shim ships
// next to the app and is resolved via the asset id below.
//
// Docs: https://dart.dev/tools/hooks
//
// NOTE: once libobs is integrated, add its include/lib flags here (flags:,
// libraries:, libraryPaths:) and define REWIND_USE_LIBOBS. Bundling libobs'
// own runtime data (data/, obs-plugins/) is separate — see ARCHITECTURE.md.
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final builder = CBuilder.library(
      name: 'rewind_obs',
      assetName: 'rewind_obs.dart',
      sources: ['native/shim/rewind_obs.c'],
      // TODO(libobs): when linking real libobs, add e.g.
      //   defines: {'REWIND_USE_LIBOBS': null},
      //   includes: ['native/third_party/obs/libobs'],
      //   libraries: ['obs'],
      //   libraryDirectories: ['native/third_party/obs/lib'],
    );
    await builder.run(
      input: input,
      output: output,
      logger: null,
    );
  });
}
