import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/clip/thumbnail_generator.dart';
import 'package:rewind/src/events/game_event.dart';

/// Counts how many generations are in flight at once.
class _CountingGenerator implements ThumbnailGenerator {
  int running = 0;
  int peak = 0;
  final _gates = <Completer<void>>[];

  @override
  Future<bool> generate(String videoPath, String thumbPath) async {
    running++;
    peak = running > peak ? running : peak;
    final gate = Completer<void>();
    _gates.add(gate);
    await gate.future;
    running--;
    File(thumbPath).parent.createSync(recursive: true);
    File(thumbPath).writeAsBytesSync(const [1, 2, 3]);
    return true;
  }

  /// Releases every generation currently waiting.
  void releaseAll() {
    final gates = List.of(_gates);
    _gates.clear();
    for (final g in gates) {
      if (!g.isCompleted) g.complete();
    }
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_thumbs'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Clip clip(int i) => Clip(
        path: '${tmp.path}/clip-$i.mp4',
        gameId: 'app:game',
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 8, 8),
        sizeBytes: 1024,
      );

  // Opening a match asks for every visible clip's thumbnail in one frame.
  // Unbounded, that pinned the machine mid-capture AND overran ffmpeg_kit's
  // session registry, whose evicted sessions then reported SESSION_NOT_FOUND
  // — recorded as "this video is broken" and never retried.
  test('generation is capped, however many are asked for at once', () async {
    final gen = _CountingGenerator();
    final cache = ThumbnailCache(gen, maxConcurrent: 2);

    final pending = [for (var i = 0; i < 18; i++) cache.ensure(clip(i))];
    await Future<void>.delayed(Duration.zero);

    expect(gen.peak, lessThanOrEqualTo(2),
        reason: '18 asked for, at most 2 running');

    for (var i = 0; i < 40 && gen.running > 0; i++) {
      gen.releaseAll();
      await Future<void>.delayed(Duration.zero);
    }
    final files = await Future.wait(pending);

    expect(files.whereType<File>().length, 18,
        reason: 'every one still gets generated — capped, not dropped');
    expect(gen.peak, lessThanOrEqualTo(2));
  });
}
