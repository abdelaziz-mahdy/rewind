// Startup smoke test: boots the REAL app entrypoint on a real device.
//
// Everything else in test/ runs in the Dart VM with no engine, no plugin
// DLLs and no native shim, so all of them pass on a build that cannot start
// at all. This one runs `lib/main.dart`'s own `main()` — plugin registration,
// MediaKit, the capture engine, tray, global hotkeys, file logging — and
// asserts the app reaches a rendered frame. CI runs it on both desktop
// platforms after the build, so "it compiles" is no longer mistaken for
// "it launches".
//
// It deliberately asserts on the log file too: a session log is the first
// thing support asks for, and its ABSENCE is what a pre-Dart launch failure
// looks like (see tools/check_bundle_deps.dart for the static counterpart —
// the Windows loader failure that motivated both).
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:rewind/main.dart' as app;
import 'package:rewind/src/log/file_log.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('app boots to a rendered frame and writes a session log',
      (t) async {
    // Any throw inside startup (a plugin that fails to register, a native
    // library that will not load, an unhandled async error) fails here.
    await app.main();

    // Bounded pumps, never pumpAndSettle: the deck runs a 1s ticker while a
    // buffer is live, and settling would wait for a timer that is doing its
    // job (CLAUDE.md, "Testing gotchas").
    await t.pump();
    await t.pump(const Duration(seconds: 1));
    await t.pump(const Duration(seconds: 1));

    expect(find.byType(MaterialApp), findsOneWidget,
        reason: 'app never got as far as building its root widget');

    final log = activeLogFile;
    expect(log, isNotNull, reason: 'startFileLogging never ran');
    expect(log!.existsSync(), isTrue,
        reason: 'no session log at ${log.path} — logging never reached disk');
    expect(log.lengthSync(), greaterThan(0),
        reason: 'session log at ${log.path} is empty');
  });
}
