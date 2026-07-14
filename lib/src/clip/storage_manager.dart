import 'clip.dart';
import 'clip_library.dart';

/// User-configurable retention policy for the clip library.
class RetentionPolicy {
  /// Max total bytes clips may occupy (null = no disk cap).
  final int? maxBytes;

  /// Delete unprotected clips older than this (null = no time cap).
  final Duration? maxAge;

  const RetentionPolicy({this.maxBytes, this.maxAge});

  static const twentyGb = RetentionPolicy(maxBytes: 20 * 1024 * 1024 * 1024);
}

/// Enforces the [RetentionPolicy] over a [ClipLibrary].
///
/// Rules:
///  - Protected/pinned clips are NEVER auto-deleted.
///  - Age policy deletes unprotected clips older than [RetentionPolicy.maxAge].
///  - Budget policy deletes the OLDEST unprotected clips until under budget.
/// Manual deletion (user-initiated) bypasses these rules and is handled
/// elsewhere.
class StorageManager {
  final ClipLibrary library;
  RetentionPolicy policy;

  StorageManager(this.library, {this.policy = RetentionPolicy.twentyGb});

  /// Run after every new clip and on a periodic sweep. Idempotent.
  Future<List<Clip>> enforce({DateTime? now}) async {
    final deleted = <Clip>[];
    final current = now ?? DateTime.now();

    // 1) Age-based pruning.
    final maxAge = policy.maxAge;
    if (maxAge != null) {
      final cutoff = current.subtract(maxAge);
      for (final clip in List<Clip>.from(library.all)) {
        if (!clip.protected && clip.createdAt.isBefore(cutoff)) {
          await _delete(clip);
          deleted.add(clip);
        }
      }
    }

    // 2) Budget-based pruning: oldest unprotected first.
    final maxBytes = policy.maxBytes;
    if (maxBytes != null) {
      final prunable = library.all.where((c) => !c.protected).toList()
        ..sort((a, b) => a.createdAt.compareTo(b.createdAt));
      var i = 0;
      while (library.totalBytes > maxBytes && i < prunable.length) {
        final clip = prunable[i++];
        await _delete(clip);
        deleted.add(clip);
      }
    }

    return deleted;
  }

  Future<void> _delete(Clip clip) async {
    // Route through the library's own deletion so related on-disk state
    // (cached thumbnails, the persisted index) is cleaned up exactly like a
    // user-initiated delete — pruning used to bypass it and orphan
    // .thumbs/ files forever. deleteClip already tolerates locked/missing
    // files without throwing.
    await library.deleteClip(clip);
  }
}
