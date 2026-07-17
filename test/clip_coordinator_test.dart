import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/clip/clip_library.dart';
import 'package:rewind/src/clip/match_stats.dart';
import 'package:rewind/src/clip/storage_manager.dart';
import 'package:rewind/src/coordinator/clip_coordinator.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/events/process_watcher_source.dart';
import 'package:rewind/src/obs/app_info.dart';
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
      // Real-time knobs shrunk so tests exercise the burst debounce and the
      // file-completeness settle without real-world waits.
      burstQuiet: const Duration(milliseconds: 60),
      fileSettleInterval: const Duration(milliseconds: 5),
    )..start(supervise: false); // subscribes to streams, no periodic timer
  });

  /// Waits out the burst debounce (60 ms) plus save + file-settle latency
  /// after emitting events. Generous margin — these are real wall-clock
  /// timers, so a tight bound flakes under load.
  Future<void> settleBurst() async =>
      Future<void>.delayed(const Duration(milliseconds: 400));

  tearDown(() {
    // On Windows a lingering file handle (mux writer / in-flight settle read)
    // can make deleteSync throw errno 32 ("in use"); the OS reclaims the temp
    // dir regardless, so don't let cleanup flake the test.
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort cleanup
    }
  });

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

  group('burst debounce (no drops, no spam)', () {
    test('a burst of events becomes ONE clip labeled with the BEST event',
        () async {
      // A fight: kill, then a double, then the penta. One clip, badged
      // pentaKill — never a burst of 44 MB dumps (the 2026-07-14 incident)
      // and never a dropped follow-up kill (the old cooldown's flaw).
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.emit(GameEventKind.kill);
      league.emit(GameEventKind.doubleKill);
      league.emit(GameEventKind.pentaKill);
      // Nothing saves while the action is hot...
      expect(engine.calls.where((c) => c == 'save'), isEmpty);

      await settleBurst();
      expect(engine.calls.where((c) => c == 'save'), hasLength(1));
      expect(library.all.single.event, GameEventKind.pentaKill);
      expect(library.all.single.killCount, 1);
    });

    test('a fresh event RESETS the quiet timer (clip extends with action)',
        () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.emit(GameEventKind.kill);
      // Keep the action alive across two would-be quiet windows.
      await Future<void>.delayed(const Duration(milliseconds: 40));
      league.emit(GameEventKind.kill);
      await Future<void>.delayed(const Duration(milliseconds: 40));
      league.emit(GameEventKind.kill);
      expect(engine.calls.where((c) => c == 'save'), isEmpty,
          reason: 'still extending — no save mid-action');

      await settleBurst();
      expect(engine.calls.where((c) => c == 'save'), hasLength(1));
      expect(library.all.single.killCount, 3,
          reason: 'every kill of the burst lands in the ONE clip');
    });

    test('the manual hotkey saves immediately, burst pending or not', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.emit(GameEventKind.kill);
      await coordinator.onHotkey();
      expect(engine.calls.where((c) => c == 'save'), hasLength(1));
      await settleBurst(); // pending burst still flushes on its own
      expect(engine.calls.where((c) => c == 'save'), hasLength(2));
    });

    test(
        'game deactivation flushes a pending burst before the buffer moves '
        'on', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.emit(GameEventKind.kill);
      league.running = false;
      await registry.tickNow();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(engine.calls.where((c) => c == 'save'), hasLength(1));
      expect(library.all.single.event, GameEventKind.kill);
    });
  });

  test('successful save persists the library index', () async {
    await coordinator.onHotkey();
    expect(File('${tmp.path}/clips.json').existsSync(), isTrue);
  });

  test('a reported path with no file on disk (stub mode) is not indexed',
      () async {
    engine.writeFile = false;
    final noGrace = ClipCoordinator(
      registry: GameRegistry(sources: []),
      library: library,
      storage: StorageManager(library),
      settings: settings,
      outDir: tmp.path,
      engine: engine,
      // Zero grace: this test's missing file is deliberate, not mux lag —
      // don't spend the real-time bounded wait on it.
      indexFileGrace: Duration.zero,
    )..start(supervise: false);
    await noGrace.onHotkey();
    expect(library.all, isEmpty);
    expect(File('${tmp.path}/clips.json').existsSync(), isFalse);
  });

  test(
      'a file that lands shortly AFTER the save reports its path is still '
      'indexed (mux lag)', () async {
    // The 2026-07-14 incident: the shim reported paths before the mux
    // helper finished writing; every clip was silently dropped from the
    // library while its file appeared moments later.
    engine.writeFile = false;
    final pending = coordinator.onHotkey();
    await Future<void>.delayed(const Duration(milliseconds: 250));
    // The file lands late, inside the grace window.
    final path = engine.lastSavedPath!;
    File(path).writeAsBytesSync(const [0, 1, 2]);
    await pending;
    expect(library.all, hasLength(1));
    expect(library.all.single.path, path);
  });

  group('onClipIndexed hook', () {
    test('fires with the newly-indexed clip after a successful save', () async {
      final indexed = <Clip>[];
      final withHook = ClipCoordinator(
        registry: registry,
        library: library,
        storage: StorageManager(library),
        settings: settings,
        outDir: tmp.path,
        engine: engine,
        onClipIndexed: (c) async => indexed.add(c),
      )..start(supervise: false);

      await withHook.onHotkey();

      expect(indexed, hasLength(1));
      expect(indexed.single, same(library.all.single));
    });

    test('does not fire when the save fails', () async {
      final indexed = <Clip>[];
      engine.failSave = true;
      final withHook = ClipCoordinator(
        registry: registry,
        library: library,
        storage: StorageManager(library),
        settings: settings,
        outDir: tmp.path,
        engine: engine,
        onClipIndexed: (c) async => indexed.add(c),
      )..start(supervise: false);

      await withHook.onHotkey();

      expect(indexed, isEmpty);
    });

    test('a null hook (the default) is simply not called', () async {
      // No onClipIndexed passed to the outer `coordinator` from setUp —
      // this just proves a save with no hook configured still succeeds.
      await coordinator.onHotkey();
      expect(library.all, hasLength(1));
    });
  });

  group('toggleRecording', () {
    test('starts with isRecording false and no start time', () {
      expect(coordinator.isRecording.value, isFalse);
      expect(coordinator.recordingStartedAt.value, isNull);
    });

    test('a full start/stop cycle adds a recording clip', () async {
      await coordinator.toggleRecording();
      expect(coordinator.isRecording.value, isTrue);
      expect(coordinator.recordingStartedAt.value, isNotNull);
      expect(engine.calls, contains('startRecording'));
      expect(library.all, isEmpty); // nothing saved until stop

      await coordinator.toggleRecording();
      expect(coordinator.isRecording.value, isFalse);
      expect(coordinator.recordingStartedAt.value, isNull);
      expect(engine.calls, contains('stopRecording'));
      expect(library.all, hasLength(1));
      expect(library.all.single.gameId, 'desktop');
      expect(library.all.single.event, GameEventKind.recording);
      expect(File(library.all.single.path).existsSync(), isTrue);
    });

    test('start attributes the recording to the active game', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      await coordinator.toggleRecording();
      await coordinator.toggleRecording();

      expect(library.all.single.gameId, 'league_of_legends');
    });

    test('failRecording surfaces an error and leaves isRecording false',
        () async {
      engine.failRecording = true;
      await coordinator.toggleRecording();
      expect(coordinator.isRecording.value, isFalse);
      expect(coordinator.lastSaveError.value, isNotNull);
      expect(library.all, isEmpty);
    });

    test('a failed stop still clears isRecording (engine-side session ended)',
        () async {
      await coordinator.toggleRecording(); // start succeeds
      expect(coordinator.isRecording.value, isTrue);

      engine.failRecording = true;
      await coordinator.toggleRecording(); // stop fails
      expect(coordinator.isRecording.value, isFalse);
      expect(coordinator.recordingStartedAt.value, isNull);
      expect(coordinator.lastSaveError.value, isNotNull);
      expect(library.all, isEmpty);
    });

    test('toggling with no capture backend (dev mode) no-ops safely', () async {
      final devCoordinator = ClipCoordinator(
        registry: GameRegistry(sources: const []),
        library: library,
        storage: StorageManager(library),
        settings: settings,
        outDir: tmp.path,
        // engine: null — dev mode
      )..start(supervise: false);

      await devCoordinator.toggleRecording();
      expect(devCoordinator.isRecording.value, isFalse);
      expect(library.all, isEmpty);
    });
  });

  group('activeGameIds', () {
    test('starts empty', () {
      expect(coordinator.activeGameIds.value, isEmpty);
    });

    test('activation adds the game', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.activeGameIds.value, {'league_of_legends'});
    });

    test('deactivation removes the game', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(coordinator.activeGameIds.value, {'league_of_legends'});

      league.running = false;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.activeGameIds.value, isEmpty);
    });

    test('two simultaneously-active games are both tracked (cross-game)',
        () async {
      league.running = true;
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(
        coordinator.activeGameIds.value,
        {'league_of_legends', 'app:stub_game'},
      );
    });

    test('deactivating one active game leaves the other tracked', () async {
      league.running = true;
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.running = false;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.activeGameIds.value, {'app:stub_game'});
    });

    test(
        'activeGame (single) still tracks only the most recent activation, '
        'independent of activeGameIds', () async {
      league.running = true;
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(coordinator.activeGameIds.value, hasLength(2));
      expect(coordinator.activeGame.value, isNotNull);
    });
  });

  group('session stamping (Clip.sessionAt)', () {
    test(
        'clips saved during one activation share the activation stamp; a '
        'desktop save carries none', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      await coordinator.onHotkey();
      await coordinator.onHotkey();
      expect(library.all, hasLength(2));
      final stamps = library.all.map((c) => c.sessionAt).toSet();
      expect(stamps, hasLength(1), reason: 'same match -> same stamp');
      expect(stamps.single, isNotNull);

      league.running = false;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      await coordinator.onHotkey(); // desktop now
      final desktopClip = library.all.firstWhere((c) => c.gameId == 'desktop');
      expect(desktopClip.sessionAt, isNull);
    });

    test('a new activation gets a fresh stamp (one session per match)',
        () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      await coordinator.onHotkey();
      final first = library.all.single.sessionAt;

      league.running = false;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      await coordinator.onHotkey();

      final second =
          library.all.firstWhere((c) => c.sessionAt != first).sessionAt;
      expect(second, isNotNull);
      expect(second, isNot(first));
    });
  });

  group('match K/D (MatchStatsStore)', () {
    test('kills and deaths during an active game accrue to its session',
        () async {
      final statsStore = MatchStatsStore(dir: tmp);
      final localLib = ClipLibrary(clipsDir: tmp);
      final localLeague = FakeGameSource('league_of_legends', 'League');
      final localRegistry = GameRegistry(sources: [localLeague]);
      final c = ClipCoordinator(
        registry: localRegistry,
        library: localLib,
        storage: StorageManager(localLib),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: engine,
        matchStats: statsStore,
      )..start(supervise: false);
      addTearDown(c.dispose);

      localLeague.running = true;
      await localRegistry.tickNow();
      await Future<void>.delayed(Duration.zero);
      final sessionStart = c.sessionStartedAtFor('league_of_legends')!;

      localLeague.emit(GameEventKind.kill);
      localLeague.emit(GameEventKind.kill);
      localLeague.emit(GameEventKind.death);
      await Future<void>.delayed(Duration.zero);

      final s = statsStore.statsFor('league_of_legends', sessionStart)!;
      expect(s.kills, 2);
      expect(s.deaths, 1);
    });

    test('a matchInfo event records champion/teams/mode, never a clip',
        () async {
      final statsStore = MatchStatsStore(dir: tmp);
      final localLib = ClipLibrary(clipsDir: tmp);
      final localLeague = FakeGameSource('league_of_legends', 'League');
      final localRegistry = GameRegistry(sources: [localLeague]);
      final c = ClipCoordinator(
        registry: localRegistry,
        library: localLib,
        storage: StorageManager(localLib),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: engine,
        matchStats: statsStore,
      )..start(supervise: false);
      addTearDown(c.dispose);

      localLeague.running = true;
      await localRegistry.tickNow();
      await Future<void>.delayed(Duration.zero);
      final sessionStart = c.sessionStartedAtFor('league_of_legends')!;

      localLeague.emitEvent(GameEvent(
        gameId: 'league_of_legends',
        kind: GameEventKind.matchInfo,
        meta: const {
          'gameMode': 'Arena',
          'champion': 'Ahri',
          'allies': [
            {'championName': 'Lux', 'championKey': null, 'riotId': 'Mate#EUW'}
          ],
          'enemies': [
            {'championName': 'Zed', 'championKey': null, 'riotId': 'Foe#EUW'}
          ],
        },
      ));
      await settleBurst();

      final s = statsStore.statsFor('league_of_legends', sessionStart)!;
      expect(s.champion, 'Ahri');
      expect(s.gameMode, 'Arena');
      expect(s.allies,
          [const MatchPlayer(championName: 'Lux', riotId: 'Mate#EUW')]);
      expect(s.enemies,
          [const MatchPlayer(championName: 'Zed', riotId: 'Foe#EUW')]);
      expect(engine.calls.where((cc) => cc == 'save'), isEmpty);
    });

    test(
        'a matchInfo event with legacy bare champion-name strings still '
        'parses (defensive: real sources always send the object shape)',
        () async {
      final statsStore = MatchStatsStore(dir: tmp);
      final localLib = ClipLibrary(clipsDir: tmp);
      final localLeague = FakeGameSource('league_of_legends', 'League');
      final localRegistry = GameRegistry(sources: [localLeague]);
      final c = ClipCoordinator(
        registry: localRegistry,
        library: localLib,
        storage: StorageManager(localLib),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: engine,
        matchStats: statsStore,
      )..start(supervise: false);
      addTearDown(c.dispose);

      localLeague.running = true;
      await localRegistry.tickNow();
      await Future<void>.delayed(Duration.zero);
      final sessionStart = c.sessionStartedAtFor('league_of_legends')!;

      localLeague.emitEvent(GameEvent(
        gameId: 'league_of_legends',
        kind: GameEventKind.matchInfo,
        meta: const {
          'allies': ['Lux'],
          'enemies': ['Zed']
        },
      ));
      await settleBurst();

      final s = statsStore.statsFor('league_of_legends', sessionStart)!;
      expect(s.allies, [const MatchPlayer(championName: 'Lux')]);
      expect(s.enemies, [const MatchPlayer(championName: 'Zed')]);
    });

    test('a statsUpdate event records the live stat line, never a clip',
        () async {
      final statsStore = MatchStatsStore(dir: tmp);
      final localLib = ClipLibrary(clipsDir: tmp);
      final localLeague = FakeGameSource('league_of_legends', 'League');
      final localRegistry = GameRegistry(sources: [localLeague]);
      final c = ClipCoordinator(
        registry: localRegistry,
        library: localLib,
        storage: StorageManager(localLib),
        settings: AppSettings(),
        outDir: tmp.path,
        engine: engine,
        matchStats: statsStore,
      )..start(supervise: false);
      addTearDown(c.dispose);

      localLeague.running = true;
      await localRegistry.tickNow();
      await Future<void>.delayed(Duration.zero);
      final sessionStart = c.sessionStartedAtFor('league_of_legends')!;

      localLeague.emitEvent(GameEvent(
        gameId: 'league_of_legends',
        kind: GameEventKind.statsUpdate,
        meta: const {
          'assists': 4,
          'creepScore': 63,
          'wardScore': 8.0,
          'items': [
            {'itemId': 1001, 'slot': 0},
          ],
        },
      ));
      await settleBurst();

      final s = statsStore.statsFor('league_of_legends', sessionStart)!;
      expect(s.assists, 4);
      expect(s.creepScore, 63);
      expect(s.wardScore, 8.0);
      expect(s.items, [const MatchItemSlot(itemId: 1001, slot: 0)]);
      expect(engine.calls.where((cc) => cc == 'save'), isEmpty);
    });

    test('a death never triggers a clip save (not in enabledEvents)', () async {
      final statsStore = MatchStatsStore(dir: tmp);
      final c = ClipCoordinator(
        registry: registry,
        library: library,
        storage: StorageManager(library),
        settings: settings,
        outDir: tmp.path,
        engine: engine,
        matchStats: statsStore,
      )..start(supervise: false);
      addTearDown(c.dispose);

      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      league.emit(GameEventKind.death);
      await settleBurst();
      expect(engine.calls.where((cc) => cc == 'save'), isEmpty);
    });
  });

  group('kill counts on clips (Clip.killCount)', () {
    test('a buffer save counts the player kills inside its buffer window',
        () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      // Three kills land (well within the default 30 s buffer window),
      // then the user saves manually.
      league.emit(GameEventKind.kill);
      league.emit(GameEventKind.kill);
      league.emit(GameEventKind.kill);
      await Future<void>.delayed(const Duration(milliseconds: 50));

      await coordinator.onHotkey();
      final manual =
          library.all.firstWhere((c) => c.event == GameEventKind.manual);
      expect(manual.killCount, 3);
    });

    test('a manual recording counts kills across its whole session', () async {
      league.running = true;
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      await coordinator.toggleRecording(); // start
      league.emit(GameEventKind.kill);
      league.emit(GameEventKind.kill);
      await Future<void>.delayed(const Duration(milliseconds: 50));
      await coordinator.toggleRecording(); // stop + save

      final rec =
          library.all.firstWhere((c) => c.event == GameEventKind.recording);
      expect(rec.killCount, 2);
    });

    test('desktop clips with no game events carry killCount 0', () async {
      await coordinator.onHotkey();
      expect(library.all.single.killCount, 0);
    });

    test('killCount round-trips through JSON', () {
      final clip = Clip(
        path: 'x',
        gameId: 'league_of_legends',
        event: GameEventKind.kill,
        createdAt: DateTime(2026, 7, 14),
        sizeBytes: 1,
        killCount: 4,
      );
      expect(Clip.fromJson(clip.toJson()).killCount, 4);
    });
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

    test(
        'activation with a matching running app captures its icon onto '
        'GameConfig.iconPath for the rail logo', () async {
      engine.apps = [
        const AppInfo(
          bundleId: 'com.rewind.stub.one',
          name: 'Stub App One',
          pid: 1001,
          iconPath: '/Applications/Stub App One.app/icon.icns',
        ),
        ...engine.apps.where((a) => a.bundleId != 'com.rewind.stub.one'),
      ];
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(settings.configFor('app:stub_game').iconPath,
          '/Applications/Stub App One.app/icon.icns');
    });

    test('never overwrites an already-captured iconPath', () async {
      settings.setConfig(GameConfig(
          gameId: 'app:stub_game', iconPath: '/already/captured.icns'));
      engine.apps = [
        const AppInfo(
          bundleId: 'com.rewind.stub.one',
          name: 'Stub App One',
          pid: 1001,
          iconPath: '/Applications/Stub App One.app/icon.icns',
        ),
        ...engine.apps.where((a) => a.bundleId != 'com.rewind.stub.one'),
      ];
      gameLister.names = ['stub.one.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(settings.configFor('app:stub_game').iconPath,
          '/already/captured.icns');
    });

    test(
        'League never has its app icon auto-captured: it IS Riot\'s '
        'official logo, which Riot policy forbids using', () async {
      // The catalog's process-watch half of League (see game_directory.
      // dart's doc on the two League gameIds) is what auto-switch acts on —
      // the vendor half has no OS process to match, so this is the only
      // path that could ever pick up an icon for it.
      final leagueLister = FakeProcessLister()..names = ['LeagueClientUx.exe'];
      final leagueWatch = ProcessWatcherSource(
        gameId: 'app:league_of_legends',
        displayName: 'League of Legends',
        processMatch: 'LeagueClientUx',
        lister: leagueLister,
      );
      final localRegistry = GameRegistry(sources: [leagueWatch]);
      final localEngine = FakeCaptureEngine()
        ..apps = [
          const AppInfo(
            bundleId: 'com.riotgames.LeagueClientUx',
            name: 'League of Legends',
            pid: 2001,
            iconPath: '/Applications/League of Legends.app/icon.icns',
          ),
        ];
      final localLib = ClipLibrary(clipsDir: tmp);
      final c = ClipCoordinator(
        registry: localRegistry,
        library: localLib,
        storage: StorageManager(localLib),
        settings: settings,
        outDir: tmp.path,
        engine: localEngine,
      )..start(supervise: false);
      addTearDown(c.dispose);

      await localRegistry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(localEngine.captureAppCalls, ['com.riotgames.LeagueClientUx']);
      expect(settings.configFor('app:league_of_legends').iconPath, isNull);
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

    test(
        'a Wine game (empty bundleId, added live via addNewSources) '
        'auto-switches to display capture (null), never an empty target',
        () async {
      // Wine games enumerate with an empty bundle id — no SCK app-capture
      // target exists (see AppInfo.bundleId) — and this one was picked
      // mid-session, so its source is adopted live rather than present
      // at construction.
      engine.apps = [
        ...engine.apps,
        const AppInfo(
            bundleId: '', name: 'PenguinHotel-Win64-Shipping', pid: 9),
      ];
      final wineLister = FakeProcessLister()
        ..names = [r'Z:\games\PenguinHotel-Win64-Shipping.exe'];
      registry.addNewSources([
        ProcessWatcherSource(
          gameId: 'app:penguinhotel_win64_shipping',
          displayName: 'PenguinHotel-Win64-Shipping',
          processMatch: 'PenguinHotel-Win64-Shipping',
          lister: wineLister,
        ),
      ]);

      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureAppCalls, [null],
          reason: 'must revert to display capture, not target ""');
      expect(
          coordinator.autoSwitchedAppName.value, 'PenguinHotel-Win64-Shipping');
    });

    test(
        'a Wine game WITH a window id auto-switches to WINDOW capture, and '
        'its exit reverts via the normal setCaptureApp path', () async {
      engine.apps = [
        ...engine.apps,
        const AppInfo(
            bundleId: '', name: 'WindowedWine', pid: 11, windowId: 4242),
      ];
      final wineLister = FakeProcessLister()..names = [r'C:\WindowedWine.exe'];
      registry.addNewSources([
        ProcessWatcherSource(
          gameId: 'app:windowedwine',
          displayName: 'WindowedWine',
          processMatch: 'WindowedWine',
          lister: wineLister,
        ),
      ]);

      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);

      expect(engine.captureWindowCalls, [4242]);
      expect(engine.captureAppCalls, isEmpty,
          reason: 'window capture — the display must not leak into clips');
      expect(coordinator.autoSwitchedAppName.value, 'WindowedWine');

      // Exit reverts through setCaptureApp(persisted) — which the shim
      // defines as also clearing the window target.
      wineLister.names = [];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(engine.captureAppCalls, [null]);
      expect(coordinator.autoSwitchedAppName.value, isNull);
    });

    test(
        'captureWineAppWindow starts window capture booked like an '
        'auto-switch (label set)', () {
      coordinator.captureWineAppWindow(
        const AppInfo(
            bundleId: '',
            name: 'PenguinHotel-Win64-Shipping',
            pid: 9,
            windowId: 777),
        gameId: 'app:penguinhotel_win64_shipping',
      );
      expect(engine.captureWindowCalls, [777]);
      expect(
          coordinator.autoSwitchedAppName.value, 'PenguinHotel-Win64-Shipping');
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
