import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/events/game_event.dart';

Future<File> _mp4(Directory dir, String name, [int bytes = 8]) async =>
    File(p.join(dir.path, name))..writeAsBytesSync(List.filled(bytes, 0));

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_lib'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('save/load round-trips clips', () async {
    final f = await _mp4(tmp, 'a.mp4');
    final lib = ClipLibrary(clipsDir: tmp)
      ..add(Clip(
          path: f.path,
          gameId: 'desktop',
          event: GameEventKind.manual,
          createdAt: DateTime(2026, 7, 1),
          sizeBytes: 8));
    await lib.save();
    final loaded = await ClipLibrary.load(tmp);
    expect(loaded.all.single.path, f.path);
    expect(loaded.all.single.event, GameEventKind.manual);
  });

  test('indexed file is not re-adopted when its stored path form differs',
      () async {
    final f = await _mp4(tmp, 'a.mp4');
    // Same physical file, non-canonical path form (extra ./ segment).
    final oddPath = p.join(tmp.path, '.', 'a.mp4');
    final lib = ClipLibrary(clipsDir: tmp)
      ..add(Clip(
          path: oddPath,
          gameId: 'league_of_legends',
          event: GameEventKind.pentaKill,
          createdAt: DateTime(2026, 7, 1),
          sizeBytes: 8));
    await lib.save();
    final loaded = await ClipLibrary.load(tmp);
    expect(loaded.all, hasLength(1), reason: 'must not double-add $f');
    expect(loaded.all.single.event, GameEventKind.pentaKill);
  });

  test('load drops entries whose file is gone', () async {
    final lib = ClipLibrary(clipsDir: tmp)
      ..add(Clip(
          path: p.join(tmp.path, 'gone.mp4'),
          gameId: 'desktop',
          event: GameEventKind.manual,
          createdAt: DateTime(2026, 7, 1),
          sizeBytes: 8));
    await lib.save();
    final loaded = await ClipLibrary.load(tmp);
    expect(loaded.all, isEmpty);
  });

  test('load adopts unknown .mp4 files as manual desktop clips', () async {
    await _mp4(tmp, 'stray.mp4', 32);
    final loaded = await ClipLibrary.load(tmp);
    expect(loaded.all.single.gameId, 'desktop');
    expect(loaded.all.single.sizeBytes, 32);
  });

  test('deleteClip removes file, entry, and persists', () async {
    final f = await _mp4(tmp, 'a.mp4');
    final lib = ClipLibrary(clipsDir: tmp)
      ..add(Clip(
          path: f.path,
          gameId: 'desktop',
          event: GameEventKind.manual,
          createdAt: DateTime(2026, 7, 1),
          sizeBytes: 8));
    await lib.save();
    await lib.deleteClip(lib.all.single);
    expect(f.existsSync(), isFalse);
    expect((await ClipLibrary.load(tmp)).all, isEmpty);
  });

  test('add notifies listeners', () async {
    final lib = ClipLibrary(clipsDir: tmp);
    var notified = 0;
    lib.addListener(() => notified++);
    lib.add(Clip(
        path: 'x',
        gameId: 'desktop',
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 7, 1),
        sizeBytes: 0));
    expect(notified, 1);
  });

  test('corrupt clips.json is backed up, library rebuilt from disk', () async {
    await _mp4(tmp, 'a.mp4');
    File(p.join(tmp.path, 'clips.json')).writeAsStringSync('{bad');
    final loaded = await ClipLibrary.load(tmp);
    expect(loaded.all, hasLength(1)); // adopted from disk scan
    expect(File(p.join(tmp.path, 'clips.json.bad')).existsSync(), isTrue);
  });
}
