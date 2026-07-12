import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'fakes/fake_capture_engine.dart';
import 'fakes/fake_game_source.dart';

void main() {
  late Directory tmp;
  late FakeCaptureEngine engine;
  late FakeGameSource league;
  late GameRegistry registry;
  late ClipLibrary library;
  late AppSettings settings;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_test');
    engine = FakeCaptureEngine();
    league = FakeGameSource('league_of_legends', 'League of Legends');
    registry = GameRegistry(sources: [league]);
    library = ClipLibrary(clipsDir: tmp);
    settings = AppSettings();
    coordinator = ClipCoordinator(
      registry: registry,
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: tmp.path,
      engine: engine,
    )..start(supervise: false); // subscribes to streams, no periodic timer
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('hotkey with no active game saves a desktop/manual clip', () async {
    await coordinator.onHotkey();
    expect(library.all, hasLength(1));
    expect(library.all.single.gameId, 'desktop');
    expect(library.all.single.event, GameEventKind.manual);
    expect(File(library.all.single.path).existsSync(), isTrue);
  });

  test('game activation applies per-game buffer length', () async {
    settings
        .setConfig(GameConfig(gameId: 'league_of_legends', bufferSeconds: 60));
    league.running = true;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero); // let activity stream deliver
    expect(engine.lastBufferSeconds, 60);
    expect(coordinator.activeGame.value, 'league_of_legends');
  });

  test('deactivation restores default buffer and clears active game', () async {
    settings
        .setConfig(GameConfig(gameId: 'league_of_legends', bufferSeconds: 60));
    league.running = true;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero);
    expect(coordinator.activeGame.value, 'league_of_legends');

    league.running = false;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero);
    expect(engine.lastBufferSeconds, settings.defaultBufferSeconds);
    expect(coordinator.activeGame.value, isNull);
  });

  test('enabled event auto-saves a clip tagged with the event kind', () async {
    league.running = true;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero);

    // _save() does async file-size work after the event is received, so wait
    // for the library to actually record the clip rather than a fixed delay.
    final saved = Completer<void>();
    library.addListener(() {
      if (!saved.isCompleted) saved.complete();
    });
    league.emit(GameEventKind.kill);
    await saved.future;

    expect(library.all, hasLength(1));
    expect(library.all.single.gameId, 'league_of_legends');
    expect(library.all.single.event, GameEventKind.kill);
  });

  test('disabled event kind does not save', () async {
    settings.setConfig(GameConfig(
      gameId: 'league_of_legends',
      enabledEvents: {GameEventKind.manual},
    ));
    league.running = true;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero);

    league.emit(GameEventKind.kill);
    await Future<void>.delayed(Duration.zero);

    expect(library.all, isEmpty);
  });

  test('autoClip=false suppresses event saves but hotkey still works',
      () async {
    settings
        .setConfig(GameConfig(gameId: 'league_of_legends', autoClip: false));
    league.running = true;
    await registry.tickNow();
    await Future<void>.delayed(Duration.zero);

    league.emit(GameEventKind.kill);
    await Future<void>.delayed(Duration.zero);
    expect(library.all, isEmpty);

    await coordinator.onHotkey();
    expect(library.all, hasLength(1));
    expect(library.all.single.gameId, 'league_of_legends');
    expect(library.all.single.event, GameEventKind.manual);
  });

  test('failed save adds nothing to the library', () async {
    engine.failSave = true;
    await coordinator.onHotkey();
    expect(library.all, isEmpty);
  });

  test('failed save surfaces the engine error via lastSaveError', () async {
    engine.failSave = true;
    await coordinator.onHotkey();
    expect(coordinator.lastSaveError.value, contains('fake save failure'));
  });

  test('a save after a failure clears lastSaveError', () async {
    engine.failSave = true;
    await coordinator.onHotkey();
    expect(coordinator.lastSaveError.value, isNotNull);

    engine.failSave = false;
    await coordinator.onHotkey();
    expect(coordinator.lastSaveError.value, isNull);
  });

  test('successful save persists the library index', () async {
    await coordinator.onHotkey();
    expect(File('${tmp.path}/clips.json').existsSync(), isTrue);
  });

  test('a reported path with no file on disk (stub mode) is not indexed',
      () async {
    engine.writeFile = false;
    await coordinator.onHotkey();
    expect(library.all, isEmpty);
    expect(File('${tmp.path}/clips.json').existsSync(), isFalse);
  });
}
