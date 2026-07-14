import 'dart:io';

import 'package:path/path.dart' as p;

import '../log/log.dart';
import 'clip.dart';
import 'thumbnail_generator.dart';

/// Lazily generates and caches thumbnail images for clips, one JPEG per clip
/// at `<clip's directory>/.thumbs/<video-basename>.jpg`. The `.thumbs`
/// subdirectory is never scanned as a clip source (see
/// `ClipLibrary.load`'s non-recursive `*.mp4`-only disk scan).
class ThumbnailCache {
  final ThumbnailGenerator generator;

  ThumbnailCache(this.generator);

  /// One in-flight generation [Future] per thumbnail path, so concurrent
  /// `ensure()` calls for the same clip (e.g. a rebuild while generation is
  /// still running) share a single generation rather than racing duplicate
  /// work.
  final Map<String, Future<File?>> _inFlight = {};

  /// Thumbnail paths that failed to generate this session — negatively
  /// cached so a broken/unsupported video isn't retried on every rebuild.
  /// Cleared per-path by [invalidate].
  final Set<String> _failed = {};

  static Directory _thumbsDirFor(String clipPath) =>
      Directory(p.join(p.dirname(clipPath), '.thumbs'));

  /// The on-disk path a thumbnail for [clipPath] would live at, whether or
  /// not it has been generated yet.
  static String thumbPathFor(String clipPath) => p.join(
        _thumbsDirFor(clipPath).path,
        '${p.basenameWithoutExtension(clipPath)}.jpg',
      );

  /// Returns the thumbnail file for [clip], generating it first if needed.
  /// Returns null if generation hasn't happened yet and either fails or is
  /// still failing from an earlier attempt this session (negative cache).
  Future<File?> ensure(Clip clip) {
    final thumbPath = thumbPathFor(clip.path);
    if (_failed.contains(thumbPath)) return Future.value(null);

    final existing = File(thumbPath);
    if (existing.existsSync()) return Future.value(existing);

    final pending = _inFlight[thumbPath];
    if (pending != null) return pending;

    final future = _generate(clip.path, thumbPath);
    _inFlight[thumbPath] = future;
    return future;
  }

  Future<File?> _generate(String clipPath, String thumbPath) async {
    try {
      // Defense in depth: ThumbnailGenerator.generate must never throw per
      // its contract, but a broken custom implementation (or a future bug)
      // must still never crash the caller — a bad thumbnail is never worth
      // more than a `null`.
      final ok = await generator.generate(clipPath, thumbPath);
      if (!ok) {
        _failed.add(thumbPath);
        return null;
      }
      return File(thumbPath);
    } catch (err, stack) {
      talker.handle(err, stack);
      _failed.add(thumbPath);
      return null;
    } finally {
      _inFlight.remove(thumbPath);
    }
  }

  /// Deletes [clip]'s cached thumbnail (e.g. after the clip itself is
  /// deleted) and clears any negative-cache entry for it.
  Future<void> invalidate(Clip clip) async {
    final thumbPath = thumbPathFor(clip.path);
    _failed.remove(thumbPath);
    try {
      final f = File(thumbPath);
      if (await f.exists()) await f.delete();
    } catch (_) {
      // Best-effort: a locked/already-gone file isn't worth surfacing.
    }
  }
}

/// Startup backfill: generates thumbnails for every clip in [clips] that
/// doesn't have one yet, one at a time with [delay] between each so a large
/// library doesn't hammer the CPU/GPU right at launch. Fire-and-forget from
/// `main()` — must never block startup, and never throws (each generation
/// already can't, per [ThumbnailGenerator]'s contract, and [ThumbnailCache]
/// swallows failures into its negative cache).
/// Startup sweep: deletes `.thumbs/*.jpg` files whose clip no longer exists
/// in [clips] — thumbnails orphaned by deletions that happened OUTSIDE the
/// app (Finder, another machine syncing the folder), which the in-app
/// delete path (`ClipLibrary.onClipDeleted` → `ThumbnailCache.invalidate`)
/// never sees. Returns the number removed; never throws (best-effort, like
/// every other cleanup here).
Future<int> removeOrphanThumbnails(List<Clip> clips, Directory clipsDir) async {
  final thumbs = Directory(p.join(clipsDir.path, '.thumbs'));
  if (!await thumbs.exists()) return 0;
  final valid = {
    for (final c in clips) p.canonicalize(ThumbnailCache.thumbPathFor(c.path)),
  };
  var removed = 0;
  try {
    await for (final f in thumbs.list()) {
      if (f is! File || p.extension(f.path).toLowerCase() != '.jpg') continue;
      if (valid.contains(p.canonicalize(f.path))) continue;
      try {
        await f.delete();
        removed++;
      } catch (_) {}
    }
  } catch (err, stack) {
    talker.handle(err, stack);
  }
  if (removed > 0) talker.info('Removed $removed orphaned thumbnail(s)');
  return removed;
}

Future<void> backfillMissingThumbnails(
  List<Clip> clips,
  ThumbnailCache cache, {
  Duration delay = const Duration(milliseconds: 300),
}) async {
  final missing = clips
      .where((c) => !File(ThumbnailCache.thumbPathFor(c.path)).existsSync())
      .toList();
  if (missing.isEmpty) return;

  var generated = 0;
  for (final clip in missing) {
    final file = await cache.ensure(clip);
    if (file != null) generated++;
    await Future<void>.delayed(delay);
  }
  talker.info(
      'Thumbnail backfill: generated $generated/${missing.length} missing thumbnails');
}
