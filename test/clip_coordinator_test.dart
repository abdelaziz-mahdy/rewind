import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/events/process_watcher_source.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'fakes/fake_capture_engine.dart';
import 'fakes/fake_game_source.dart';
import 'fakes/fake_process_lister.dart';

void main() {
  late Directory tmp;
  late FakeCaptureEngine engine;
  late FakeGameSource league;
  // Matches FakeCaptureEngine's "Stub App One" (bundleId com.rewind.stub.one)
  // — used by the auto-switch-capture tests below.
  late FakeProcessLister gameLister;
  late ProcessWatcherSource game;
  // A source whose processMatch matches no entry in
  // FakeCaptureEngine.apps — used by the "no matching window yet" test.
  late FakeProcessLister noMatchLister;
  late ProcessWatcherSource noMatchGame;
  late GameRegistry registry;
  late ClipLibrary library;
  late AppSettings settings;
  late ClipCoordinator coordinator;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('rewind_test');
    engine = FakeCaptureEngine();
    league = FakeGameSource('league_of_legends', 'League of Legends');
    gameLister = FakeProcessLister();
    game = ProcessWatcherSource(
      gameId: 'app:stub_game',
      displayName: 'Stub Game',
      processMatch: 'stub.one',
      lister: gameLister,
    );
    noMatchLister = FakeProcessLister();
    noMatchGame = ProcessWatcherSource(
      gameId: 'app:no_match_game',
      displayName: 'No Match Game',
      processMatch: 'totally-unmatched-app',
      lister: noMatchLister,
    );
    registry = GameRegistry(sources: [league, game, noMatchGame]);
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

    // library.addListener fires on add(), which happens *before*
    // library.save() finishes writing clips.json.tmp. Without waiting for
    // that write to land, tearDown's directory delete below can race it and
    // throw a PathNotFoundException from inside _save's try block (harmless
    // — caught and logged — but noisy and nondeterministic under `flutter
    // test`'s parallel isolates). Poll with a bound so a genuine regression
    // still fails fast instead of hanging.
    final clipsJson = File('${tmp.path}/clips.json');
    final deadline = DateTime.now().add(const Duration(seconds: 2));
    while (!clipsJson.existsSync() && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }

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

  test('two consecutive identical failures both notify listeners', () async {
    // ValueNotifier dedups equal values, so without the coordinator's
    // null-then-set trick, a second failure with the same message would
    // never notify — no second SnackBar, reproducing "pressed it and
    // nothing happened" for a user who keeps hitting a still-broken save.
    engine.failSave = true;
    var errorNotifications = 0;
    coordinator.lastSaveError.addListener(() {
      if (coordinator.lastSaveError.value != null) errorNotifications++;
    });

    await coordinator.onHotkey();
    await coordinator.onHotkey();

    expect(errorNotifications, 2);
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

  group('auto-switch capture', () {
    test(
        'activation with a matching running app switches capture without '
        'persisting the choice', () async {
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, ['com.rewind.stub.one']);
      expect(settings.captureAppBundleId, isNull);
    });

    test('deactivation reverts capture to null when no persisted choice',
        () async {
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(engine.captureAppCalls, ['com.rewind.stub.one']);

      gameLister.names = [];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, ['com.rewind.stub.one', null]);
    });

    test('deactivation reverts capture to the persisted choice when set',
        () async {
      settings.captureAppBundleId = 'com.persisted.app';
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      gameLister.names = [];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(
          engine.captureAppCalls, ['com.rewind.stub.one', 'com.persisted.app']);
    });

    test('autoSwitchCapture=false makes activation not switch capture',
        () async {
      settings.autoSwitchCapture = false;
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, isEmpty);
    });

    test('no matching capturable app makes no capture switch call', () async {
      noMatchLister.names = ['totally-unmatched-app.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, isEmpty);
    });

    test(
        'a game without a processMatch (e.g. League) does not switch '
        'capture', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, isEmpty);
    });

    test('sets autoSwitchedAppName to the matched app on activation switch',
        () async {
      expect(coordinator.autoSwitchedAppName.value, isNull);

      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.autoSwitchedAppName.value, 'Stub App One');
    });

    test('clears autoSwitchedAppName when the auto-switched game deactivates',
        () async {
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.autoSwitchedAppName.value, 'Stub App One');

      gameLister.names = [];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.autoSwitchedAppName.value, isNull);
    });
  });
}
