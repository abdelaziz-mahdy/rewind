import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/log/log.dart';
import 'package:rewind/src/log/obs_log.dart';
import 'package:rewind/src/obs/capture_engine.dart';

import 'fakes/fake_capture_engine.dart';

void main() {
  late List<String> lines;
  StreamSubscription<dynamic>? sub;

  setUp(() {
    lines = [];
    // One subscription per test, cancelled after: talker's stream is
    // app-global, so a leaked listener keeps appending into the next test's
    // list too (they all close over the same variable).
    sub = talker.stream
        .listen((it) => lines.add('${it.logLevel?.name}|${it.message}'));
  });
  tearDown(() => sub?.cancel());

  test('a null engine (dev mode, failed init) is not an error', () {
    expect(() => forwardObsLog(null), returnsNormally);
  });

  test('libobs levels map onto the app logger, tagged as libobs', () async {
    final engine = FakeCaptureEngine()
      ..obsLogLines.addAll(const [
        ObsLogLine(level: 100, message: 'Failed to start replay buffer'),
        ObsLogLine(level: 200, message: 'SCK stream stopped'),
        ObsLogLine(level: 300, message: 'Loaded plugin mac-capture'),
      ]);

    forwardObsLog(engine);
    await Future<void>.delayed(Duration.zero);

    expect(lines, [
      'error|libobs: Failed to start replay buffer',
      'warning|libobs: SCK stream stopped',
      'info|libobs: Loaded plugin mac-capture',
    ]);
  });

  // The shim's ring hands each line out once. Forwarding twice must not
  // reprint the whole ring on every perf tick.
  test('draining consumes: a second pass forwards nothing', () async {
    final engine = FakeCaptureEngine()
      ..obsLogLines.add(const ObsLogLine(level: 300, message: 'once'));

    forwardObsLog(engine);
    forwardObsLog(engine);
    await Future<void>.delayed(Duration.zero);

    expect(lines.where((l) => l.contains('once')), hasLength(1));
  });
}
