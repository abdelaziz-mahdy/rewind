import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/thumbnail_cache.dart';
import 'package:rewind/src/events/game_event.dart';
import 'fakes/fake_thumbnail_generator.dart';

Clip _clip(String path) => Clip(
      path: path,
      gameId: 'desktop',
      event: GameEventKind.manual,
      createdAt: DateTime(2026, 7, 1),
      sizeBytes: 8,
    );

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_thumbs'));
  tearDown(() => tmp.deleteSync(recursive: true));

  group('thumbPathFor', () {
    test(
        'lives in a .thumbs subdirectory beside the clip, same basename + .jpg',
        () {
      final clipPath = p.join(tmp.path, 'clip-123.mp4');
      expect(
        ThumbnailCache.thumbPathFor(clipPath),
        p.join(tmp.path, '.thumbs', 'clip-123.jpg'),
      );
    });
  });

  group('ensure', () {
    test('generates once and returns the file on success', () async {
      final clipFile = File(p.join(tmp.path, 'a.mp4'))..writeAsBytesSync([0]);
      final generator = FakeThumbnailGenerator();
      final cache = ThumbnailCache(generator);

      final file = await cache.ensure(_clip(clipFile.path));

      expect(file, isNotNull);
      expect(file!.existsSync(), isTrue);
      expect(file.path, ThumbnailCache.thumbPathFor(clipFile.path));
      expect(generator.callCount, 1);
    });

    test('a second ensure() for an already-generated thumb does not regenerate',
        () async {
      final clipFile = File(p.join(tmp.path, 'a.mp4'))..writeAsBytesSync([0]);
      final generator = FakeThumbnailGenerator();
      final cache = ThumbnailCache(generator);
      final clip = _clip(clipFile.path);

      await cache.ensure(clip);
      await cache.ensure(clip);

      expect(generator.callCount, 1);
    });

    test(
        'concurrent ensure() calls for the same clip share one generation '
        '(single-flight)', () async {
      final clipFile = File(p.join(tmp.path, 'a.mp4'))..writeAsBytesSync([0]);
      final generator =
          FakeThumbnailGenerator(delay: const Duration(milliseconds: 50));
      final cache = ThumbnailCache(generator);
      final clip = _clip(clipFile.path);

      final results = await Future.wait([
        cache.ensure(clip),
        cache.ensure(clip),
        cache.ensure(clip),
      ]);

      expect(generator.callCount, 1);
      expect(results.every((f) => f != null), isTrue);
    });

    test(
        'a failed generation returns null and is negatively cached '
        '(not retried this session)', () async {
      final clipFile = File(p.join(tmp.path, 'broken.mp4'))
        ..writeAsBytesSync([0]);
      final generator = FakeThumbnailGenerator(failFor: {clipFile.path});
      final cache = ThumbnailCache(generator);
      final clip = _clip(clipFile.path);

      final first = await cache.ensure(clip);
      final second = await cache.ensure(clip);

      expect(first, isNull);
      expect(second, isNull);
      expect(generator.callCount, 1, reason: 'must not retry after a failure');
    });

    test('invalidate deletes the cached file and clears the negative cache',
        () async {
      final clipFile = File(p.join(tmp.path, 'broken.mp4'))
        ..writeAsBytesSync([0]);
      final generator = FakeThumbnailGenerator(failFor: {clipFile.path});
      final cache = ThumbnailCache(generator);
      final clip = _clip(clipFile.path);

      await cache.ensure(clip); // fails, negatively cached
      generator.failFor.clear();
      await cache.invalidate(clip);
      final retried = await cache.ensure(clip);

      expect(retried, isNotNull);
      expect(generator.callCount, 2);
    });

    test('invalidate deletes an already-generated thumbnail file', () async {
      final clipFile = File(p.join(tmp.path, 'a.mp4'))..writeAsBytesSync([0]);
      final generator = FakeThumbnailGenerator();
      final cache = ThumbnailCache(generator);
      final clip = _clip(clipFile.path);

      final file = await cache.ensure(clip);
      expect(file!.existsSync(), isTrue);

      await cache.invalidate(clip);
      expect(file.existsSync(), isFalse);
    });
  });

  group('backfillMissingThumbnails', () {
    test('generates only for clips without an existing thumbnail', () async {
      final withThumb = File(p.join(tmp.path, 'has-thumb.mp4'))
        ..writeAsBytesSync([0]);
      final withoutThumb = File(p.join(tmp.path, 'no-thumb.mp4'))
        ..writeAsBytesSync([0]);
      // Pre-seed a thumbnail for `withThumb`.
      final preExisting = File(ThumbnailCache.thumbPathFor(withThumb.path));
      await preExisting.parent.create(recursive: true);
      await preExisting.writeAsBytes([0xFF]);

      final generator = FakeThumbnailGenerator();
      final cache = ThumbnailCache(generator);

      await backfillMissingThumbnails(
        [_clip(withThumb.path), _clip(withoutThumb.path)],
        cache,
        delay: Duration.zero,
      );

      expect(generator.generatedFor, [withoutThumb.path]);
    });

    test(
        'an empty-backfill (all clips already have thumbnails) generates '
        'nothing', () async {
      final withThumb = File(p.join(tmp.path, 'has-thumb.mp4'))
        ..writeAsBytesSync([0]);
      final preExisting = File(ThumbnailCache.thumbPathFor(withThumb.path));
      await preExisting.parent.create(recursive: true);
      await preExisting.writeAsBytes([0xFF]);

      final generator = FakeThumbnailGenerator();
      final cache = ThumbnailCache(generator);

      await backfillMissingThumbnails([_clip(withThumb.path)], cache,
          delay: Duration.zero);

      expect(generator.callCount, 0);
    });
  });

  group('removeOrphanThumbnails', () {
    test('deletes thumbs whose clip is gone, keeps live ones', () async {
      final clipFile = File(p.join(tmp.path, 'alive.mp4'))
        ..writeAsBytesSync([0]);
      final clip = Clip(
          path: clipFile.path,
          gameId: 'desktop',
          event: GameEventKind.manual,
          createdAt: DateTime(2026, 7, 1),
          sizeBytes: 1);
      final thumbs = Directory(p.join(tmp.path, '.thumbs'))
        ..createSync(recursive: true);
      final live = File(ThumbnailCache.thumbPathFor(clipFile.path))
        ..writeAsBytesSync([1]);
      final orphan = File(p.join(thumbs.path, 'deleted-elsewhere.jpg'))
        ..writeAsBytesSync([2]);
      // Non-jpg files (e.g. .DS_Store) must never be touched.
      final bystander = File(p.join(thumbs.path, '.DS_Store'))
        ..writeAsBytesSync([3]);

      final removed = await removeOrphanThumbnails([clip], tmp);

      expect(removed, 1);
      expect(live.existsSync(), isTrue);
      expect(orphan.existsSync(), isFalse);
      expect(bystander.existsSync(), isTrue);
    });

    test('no .thumbs directory is a no-op', () async {
      expect(await removeOrphanThumbnails(const [], tmp), 0);
    });
  });
}
