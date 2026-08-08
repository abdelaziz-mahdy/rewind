import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/duration_prober.dart';
import 'package:rewind/src/events/game_event.dart';

class _FakeProber implements DurationProber {
  final Map<String, Duration?> answers;
  final probed = <String>[];
  _FakeProber(this.answers);

  @override
  Future<Duration?> probe(String path) async {
    probed.add(path);
    return answers[path];
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_dur'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  /// Writes the file too: ClipLibrary.load rebuilds from the DISK scan, so
  /// an index entry whose file is missing is dropped on reload.
  Clip clip(String name, {int? durationMs}) {
    File('${tmp.path}/$name.mp4').writeAsBytesSync(const [0]);
    return Clip(
        path: '${tmp.path}/$name.mp4',
        gameId: 'app:game',
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 8, 8),
        sizeBytes: 1024,
        durationMs: durationMs);
  }

  group('backfillDurations', () {
    test('fills only what is missing, and persists', () async {
      final lib = ClipLibrary(clipsDir: tmp);
      lib.add(clip('a'));
      lib.add(clip('b', durationMs: 5000));
      final prober = _FakeProber({
        '${tmp.path}/a.mp4': const Duration(seconds: 30),
      });

      await lib.backfillDurations(prober);

      expect(prober.probed, ['${tmp.path}/a.mp4'],
          reason: 'the clip that already knows its length is not re-read');
      final reloaded = await ClipLibrary.load(tmp);
      final a = reloaded.all.firstWhere((c) => c.path.endsWith('a.mp4'));
      expect(a.durationMs, 30000, reason: 'and it survives a reload');
    });

    test('an unreadable file leaves the clip alone, no crash', () async {
      final lib = ClipLibrary(clipsDir: tmp);
      lib.add(clip('gone'));

      await lib.backfillDurations(_FakeProber({'${tmp.path}/gone.mp4': null}));

      expect(lib.all.single.durationMs, isNull);
    });

    test('nothing missing is a no-op', () async {
      final lib = ClipLibrary(clipsDir: tmp);
      lib.add(clip('a', durationMs: 1000));
      final prober = _FakeProber({});

      await lib.backfillDurations(prober);

      expect(prober.probed, isEmpty);
    });
  });
}
