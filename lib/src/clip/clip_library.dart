import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import '../events/game_event.dart';
import 'clip.dart';

/// Index of saved clips, persisted as clips.json inside the clips directory
/// and reconciled with what is actually on disk at load time.
class ClipLibrary extends ChangeNotifier {
  final Directory clipsDir;
  final List<Clip> _clips = [];

  ClipLibrary({required this.clipsDir});

  List<Clip> get all => List.unmodifiable(_clips);
  int get totalBytes => _clips.fold(0, (sum, c) => sum + c.sizeBytes);

  File get _index => File(p.join(clipsDir.path, 'clips.json'));

  void add(Clip clip) {
    _clips.add(clip);
    notifyListeners();
  }

  void remove(Clip clip) {
    _clips.remove(clip);
    notifyListeners();
  }

  void setProtected(Clip clip, bool value) {
    clip.protected = value;
    notifyListeners();
  }

  /// Delete the file and its entry (user-initiated), then persist.
  Future<void> deleteClip(Clip clip) async {
    try {
      final f = File(clip.path);
      if (await f.exists()) await f.delete();
    } catch (_) {}
    remove(clip);
    await save();
  }

  Future<void> save() async {
    await clipsDir.create(recursive: true);
    final tmp = File('${_index.path}.tmp');
    await tmp.writeAsString(const JsonEncoder.withIndent('  ')
        .convert({'clips': _clips.map((c) => c.toJson()).toList()}));
    await tmp.rename(_index.path);
  }

  /// Load the index and reconcile with disk: entries whose file vanished are
  /// dropped; .mp4 files with no entry are adopted as manual desktop clips.
  static Future<ClipLibrary> load(Directory clipsDir) async {
    final lib = ClipLibrary(clipsDir: clipsDir);
    final known = <String>{};
    final index = lib._index;
    if (await index.exists()) {
      try {
        final j = jsonDecode(await index.readAsString()) as Map;
        for (final e in (j['clips'] as List? ?? const [])) {
          final clip = Clip.fromJson((e as Map).cast<String, dynamic>());
          if (File(clip.path).existsSync()) {
            lib._clips.add(clip);
            known.add(clip.path);
          }
        }
      } catch (_) {
        try {
          await index.rename('${index.path}.bad');
        } catch (_) {}
      }
    }
    if (await clipsDir.exists()) {
      await for (final f in clipsDir.list()) {
        if (f is File &&
            p.extension(f.path).toLowerCase() == '.mp4' &&
            !known.contains(f.path)) {
          final stat = f.statSync();
          lib._clips.add(Clip(
            path: f.path,
            gameId: 'desktop',
            event: GameEventKind.manual,
            createdAt: stat.modified,
            sizeBytes: stat.size,
          ));
        }
      }
    }
    lib._clips.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return lib;
  }
}
