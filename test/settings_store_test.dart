import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/settings/settings_store.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_settings'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('load with no file returns defaults', () async {
    final s = await SettingsStore(tmp).load();
    expect(s.defaultBufferSeconds, 30);
    expect(s.hotkey, 'Alt+F10');
    expect(s.captureDisplayUuid, isNull);
  });

  test('recordHotkey defaults to Alt+F9', () {
    expect(AppSettings().recordHotkey, 'Alt+F9');
  });

  test('recordHotkey round-trips through toJson/fromJson', () {
    final s = AppSettings(recordHotkey: 'Ctrl+F9');
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.recordHotkey, 'Ctrl+F9');
  });

  test('recordHotkey round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(recordHotkey: 'Ctrl+F9'));
    final loaded = await store.load();
    expect(loaded.recordHotkey, 'Ctrl+F9');
  });

  test('captureDisplayUuid round-trips through toJson/fromJson', () {
    final s = AppSettings(captureDisplayUuid: 'display-uuid-123');
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.captureDisplayUuid, 'display-uuid-123');
  });

  test('captureDisplayUuid round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(captureDisplayUuid: 'display-uuid-456'));
    final loaded = await store.load();
    expect(loaded.captureDisplayUuid, 'display-uuid-456');
  });

  test('micDeviceUid defaults to null (system default)', () {
    expect(AppSettings().micDeviceUid, isNull);
  });

  test('micDeviceUid round-trips through toJson/fromJson', () {
    final s = AppSettings(micDeviceUid: 'mic-uid-123');
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.micDeviceUid, 'mic-uid-123');
  });

  test('micDeviceUid round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(micDeviceUid: 'mic-uid-456'));
    final loaded = await store.load();
    expect(loaded.micDeviceUid, 'mic-uid-456');
  });

  test(
      'fromJson with no micDeviceUid key (pre-existing settings file) '
      'falls back to null, not a crash', () {
    final json = AppSettings().toJson()..remove('micDeviceUid');
    final loaded = AppSettings.fromJson(json);
    expect(loaded.micDeviceUid, isNull);
  });

  test('micVolume defaults to 1.0 (100%)', () {
    expect(AppSettings().micVolume, 1.0);
  });

  test('micVolume round-trips through toJson/fromJson', () {
    final s = AppSettings(micVolume: 1.5);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.micVolume, 1.5);
  });

  test('micVolume round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(micVolume: 0.5));
    final loaded = await store.load();
    expect(loaded.micVolume, 0.5);
  });

  test(
      'fromJson with no micVolume key (pre-existing settings file) falls '
      'back to 1.0, not a crash', () {
    final json = AppSettings().toJson()..remove('micVolume');
    final loaded = AppSettings.fromJson(json);
    expect(loaded.micVolume, 1.0);
  });

  test('fromJson clamps an out-of-range stored micVolume to 0.0-2.0', () {
    expect(AppSettings.fromJson({'micVolume': 5.0}).micVolume, 2.0);
    expect(AppSettings.fromJson({'micVolume': -1.0}).micVolume, 0.0);
  });

  test('gameAudioVolume defaults to 1.0 (100%)', () {
    expect(AppSettings().gameAudioVolume, 1.0);
  });

  test('gameAudioVolume round-trips through toJson/fromJson', () {
    final s = AppSettings(gameAudioVolume: 0.5);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.gameAudioVolume, 0.5);
  });

  test('gameAudioVolume round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(gameAudioVolume: 1.5));
    final loaded = await store.load();
    expect(loaded.gameAudioVolume, 1.5);
  });

  test(
      'fromJson with no gameAudioVolume key (pre-existing settings file) '
      'falls back to 1.0, not a crash', () {
    final json = AppSettings().toJson()..remove('gameAudioVolume');
    final loaded = AppSettings.fromJson(json);
    expect(loaded.gameAudioVolume, 1.0);
  });

  test('fromJson clamps an out-of-range stored gameAudioVolume to 0.0-2.0', () {
    expect(AppSettings.fromJson({'gameAudioVolume': 5.0}).gameAudioVolume, 2.0);
    expect(
        AppSettings.fromJson({'gameAudioVolume': -1.0}).gameAudioVolume, 0.0);
  });

  test('micAutoLevel defaults to true', () {
    expect(AppSettings().micAutoLevel, isTrue);
  });

  test('micNoiseSuppression defaults to true', () {
    expect(AppSettings().micNoiseSuppression, isTrue);
  });

  test('micNoiseSuppression round-trips through toJson/fromJson', () {
    final s = AppSettings(micNoiseSuppression: false);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.micNoiseSuppression, isFalse);
  });

  test(
      'fromJson with no micNoiseSuppression key (pre-existing settings file) '
      'falls back to true — suppression is on by default', () {
    final json = AppSettings().toJson()..remove('micNoiseSuppression');
    expect(AppSettings.fromJson(json).micNoiseSuppression, isTrue);
  });

  test('micAutoLevel round-trips through toJson/fromJson', () {
    final s = AppSettings(micAutoLevel: false);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.micAutoLevel, isFalse);
  });

  test('micAutoLevel round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(micAutoLevel: false));
    final loaded = await store.load();
    expect(loaded.micAutoLevel, isFalse);
  });

  test(
      'fromJson with no micAutoLevel key (pre-existing settings file) falls '
      'back to true — auto-leveling is on by default', () {
    final json = AppSettings().toJson()..remove('micAutoLevel');
    final loaded = AppSettings.fromJson(json);
    expect(loaded.micAutoLevel, isTrue);
  });

  test('save/load round-trips per-game config', () async {
    final store = SettingsStore(tmp);
    final s = AppSettings(defaultBufferSeconds: 60, hotkey: 'Ctrl+Shift+S');
    s.setConfig(GameConfig(gameId: 'league_of_legends', bufferSeconds: 90));
    await store.save(s);
    final loaded = await store.load();
    expect(loaded.defaultBufferSeconds, 60);
    expect(loaded.hotkey, 'Ctrl+Shift+S');
    expect(loaded.configFor('league_of_legends').bufferSeconds, 90);
  });

  test('captureAppBundleId round-trips through toJson/fromJson', () {
    final s = AppSettings(captureAppBundleId: 'com.example.app');
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.captureAppBundleId, 'com.example.app');
  });

  test('captureAppBundleId round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(captureAppBundleId: 'com.example.app'));
    final loaded = await store.load();
    expect(loaded.captureAppBundleId, 'com.example.app');
  });

  test('null captureAppBundleId round-trips as null (not overwritten)',
      () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings());
    final loaded = await store.load();
    expect(loaded.captureAppBundleId, isNull);
  });

  test('GameConfig.processMatch round-trips through toJson/fromJson', () {
    final s = AppSettings();
    s.setConfig(GameConfig(gameId: 'app:cs2', processMatch: 'cs2'));
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.configFor('app:cs2').processMatch, 'cs2');
  });

  test('GameConfig.processMatch round-trips through the settings store',
      () async {
    final store = SettingsStore(tmp);
    final s = AppSettings();
    s.setConfig(GameConfig(gameId: 'app:cs2', processMatch: 'cs2'));
    await store.save(s);
    final loaded = await store.load();
    expect(loaded.configFor('app:cs2').processMatch, 'cs2');
  });

  test('autoSwitchCapture defaults to true', () {
    expect(AppSettings().autoSwitchCapture, isTrue);
  });

  test('autoSwitchCapture round-trips through toJson/fromJson', () {
    final s = AppSettings(autoSwitchCapture: false);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.autoSwitchCapture, isFalse);
  });

  test('autoSwitchCapture round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(autoSwitchCapture: false));
    final loaded = await store.load();
    expect(loaded.autoSwitchCapture, isFalse);
  });

  test(
      'playFeedbackSounds defaults to true and round-trips through '
      'toJson/fromJson', () {
    final s = AppSettings(playFeedbackSounds: false);
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.playFeedbackSounds, isFalse);
    expect(AppSettings().playFeedbackSounds, isTrue);
  });

  test(
      'playFeedbackSounds falls back to true on an absent key (settings '
      'file predating this feature)', () {
    final j = AppSettings().toJson()..remove('playFeedbackSounds');
    expect(AppSettings.fromJson(j).playFeedbackSounds, isTrue);
  });

  test('playFeedbackSounds round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(playFeedbackSounds: false));
    final loaded = await store.load();
    expect(loaded.playFeedbackSounds, isFalse);
  });

  test('GameConfig.processMatch defaults to null when absent', () {
    final s = AppSettings()..setConfig(GameConfig(gameId: 'g'));
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.configFor('g').processMatch, isNull);
  });

  test('captureAppName round-trips through toJson/fromJson', () {
    final s = AppSettings(
        captureAppBundleId: 'com.codeweavers.CrossOver',
        captureAppName: 'PenguinHotel-Win64-Shipping');
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.captureAppName, 'PenguinHotel-Win64-Shipping');
  });

  test('null captureAppName round-trips as null', () {
    expect(AppSettings.fromJson(AppSettings().toJson()).captureAppName, isNull);
  });

  test('GameConfig.displayName round-trips through toJson/fromJson', () {
    final s = AppSettings();
    s.setConfig(GameConfig(
        gameId: 'app:penguinhotel_win64_shipping',
        displayName: 'PenguinHotel-Win64-Shipping'));
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.configFor('app:penguinhotel_win64_shipping').displayName,
        'PenguinHotel-Win64-Shipping');
  });

  test('GameConfig.iconPath round-trips through toJson/fromJson', () {
    final s = AppSettings();
    s.setConfig(GameConfig(
        gameId: 'league_of_legends',
        iconPath: '/Applications/League of Legends.app/Contents/Resources/'
            'icon.icns'));
    final loaded = AppSettings.fromJson(s.toJson());
    expect(
        loaded.configFor('league_of_legends').iconPath,
        '/Applications/League of Legends.app/Contents/Resources/'
        'icon.icns');
  });

  test('GameConfig.iconPath defaults to null when absent', () {
    final s = AppSettings()..setConfig(GameConfig(gameId: 'g'));
    final loaded = AppSettings.fromJson(s.toJson());
    expect(loaded.configFor('g').iconPath, isNull);
  });

  test('GameConfig default enabledEvents includes achievement', () {
    // Any Steam achievement event must pass a fresh (never-configured)
    // game's gate — see ClipCoordinator's autoClip/enabledEvents check and
    // SteamAchievementWatcher's fallback `steam:<appid>` gameId, which
    // always resolves through AppSettings.configFor's default constructor.
    expect(GameConfig(gameId: 'g').enabledEvents,
        contains(GameEventKind.achievement));
  });

  group('GameConfig.postEventSeconds', () {
    test('defaults to 5', () {
      expect(GameConfig(gameId: 'g').postEventSeconds, 5);
    });

    test('round-trips through toJson/fromJson', () {
      final s = AppSettings()
        ..setConfig(GameConfig(gameId: 'g', postEventSeconds: 8));
      final loaded = AppSettings.fromJson(s.toJson());
      expect(loaded.configFor('g').postEventSeconds, 8);
    });

    test('round-trips through the settings store', () async {
      final store = SettingsStore(tmp);
      final s = AppSettings()
        ..setConfig(GameConfig(gameId: 'g', postEventSeconds: 3));
      await store.save(s);
      final loaded = await store.load();
      expect(loaded.configFor('g').postEventSeconds, 3);
    });

    test(
        'an absent key (settings file predating this feature) falls back '
        'to 5', () {
      final j = AppSettings().toJson();
      (j['perGame'] as Map)['g'] = GameConfig(gameId: 'g').toJson()
        ..remove('postEventSeconds');
      final loaded = AppSettings.fromJson(j);
      expect(loaded.configFor('g').postEventSeconds, 5);
    });
  });

  group('AppSettings.postEventSecondsFor', () {
    test('returns the 5 s default for a game with no config row', () {
      expect(AppSettings().postEventSecondsFor('unconfigured_game'), 5);
    });

    test('returns null-gameId as the 5 s default too', () {
      expect(AppSettings().postEventSecondsFor(null), 5);
    });

    test('returns the per-game override when a config row exists', () {
      final s = AppSettings()
        ..setConfig(GameConfig(gameId: 'g', postEventSeconds: 10));
      expect(s.postEventSecondsFor('g'), 10);
    });

    test('never creates/persists a row (unlike configFor)', () {
      final s = AppSettings();
      s.postEventSecondsFor('g');
      expect(s.allConfigs, isEmpty);
    });
  });

  group('storage/cleanup settings', () {
    test('maxStorageGb defaults to 20 and round-trips', () {
      expect(AppSettings().maxStorageGb, 20);
      final s = AppSettings(maxStorageGb: 50);
      expect(AppSettings.fromJson(s.toJson()).maxStorageGb, 50);
    });

    test('a stored null maxStorageGb means UNLIMITED and survives reload', () {
      final s = AppSettings(maxStorageGb: null);
      expect(AppSettings.fromJson(s.toJson()).maxStorageGb, isNull);
    });

    test('a settings file predating the key falls back to the 20 GB default',
        () {
      final j = AppSettings().toJson()..remove('maxStorageGb');
      expect(AppSettings.fromJson(j).maxStorageGb, 20);
    });

    test('maxClipAgeDays defaults to null (never) and round-trips', () {
      expect(AppSettings().maxClipAgeDays, isNull);
      final s = AppSettings(maxClipAgeDays: 14);
      expect(AppSettings.fromJson(s.toJson()).maxClipAgeDays, 14);
    });

    test('clipsDirPath round-trips (null = per-OS default)', () {
      expect(AppSettings().clipsDirPath, isNull);
      final s = AppSettings(clipsDirPath: '/Volumes/gaming/Clips');
      expect(AppSettings.fromJson(s.toJson()).clipsDirPath,
          '/Volumes/gaming/Clips');
    });

    test('onboardingComplete defaults to false and round-trips', () {
      expect(AppSettings().onboardingComplete, isFalse);
      final s = AppSettings(onboardingComplete: true);
      expect(AppSettings.fromJson(s.toJson()).onboardingComplete, isTrue);
    });

    test('capture quality + audio defaults and round-trip', () {
      final d = AppSettings();
      expect(d.captureFps, 60);
      // 1080, the Balanced tier — deliberately NOT null/native (see
      // VideoPreset's doc: the default must be universally disk-safe).
      expect(d.captureMaxHeight, 1080);
      expect(d.audioMode, AudioMode.all);

      // An existing file that stored a deliberate null (= Source) keeps it —
      // the new constructor default must not override a saved choice.
      final sourceUser =
          AppSettings.fromJson(AppSettings(captureMaxHeight: null).toJson());
      expect(sourceUser.captureMaxHeight, isNull);

      final s = AppSettings(
          captureFps: 30, captureMaxHeight: 1080, audioMode: AudioMode.app);
      final loaded = AppSettings.fromJson(s.toJson());
      expect(loaded.captureFps, 30);
      expect(loaded.captureMaxHeight, 1080);
      expect(loaded.audioMode, AudioMode.app);
    });

    test('legacy captureSystemAudio migrates to an AudioMode', () {
      // Old settings files stored a bool; false -> off, true -> all.
      expect(AppSettings.fromJson({'captureSystemAudio': false}).audioMode,
          AudioMode.off);
      expect(AppSettings.fromJson({'captureSystemAudio': true}).audioMode,
          AudioMode.all);
      // A file with neither key defaults to all.
      expect(AppSettings.fromJson({}).audioMode, AudioMode.all);
    });
  });

  test('captureMicrophone defaults to OFF and round-trips', () {
    expect(AppSettings().captureMicrophone, isFalse);
    final s = AppSettings(captureMicrophone: true);
    expect(AppSettings.fromJson(s.toJson()).captureMicrophone, isTrue);
  });

  test('captureOnlyInGame defaults to ON and round-trips an explicit false',
      () {
    expect(AppSettings().captureOnlyInGame, isTrue);
    final s = AppSettings(captureOnlyInGame: false);
    expect(AppSettings.fromJson(s.toJson()).captureOnlyInGame, isFalse);
  });

  test('captureOnlyInGame round-trips through the settings store', () async {
    final store = SettingsStore(tmp);
    await store.save(AppSettings(captureOnlyInGame: false));
    final loaded = await store.load();
    expect(loaded.captureOnlyInGame, isFalse);
  });

  test(
      'fromJson with no captureOnlyInGame key (settings file predating the '
      '2026-07-18 default flip) falls back to ON', () {
    final json = AppSettings().toJson()..remove('captureOnlyInGame');
    final loaded = AppSettings.fromJson(json);
    expect(loaded.captureOnlyInGame, isTrue);
  });

  test('corrupt file is backed up and defaults returned', () async {
    final store = SettingsStore(tmp);
    store.file.writeAsStringSync('{not json');
    final s = await store.load();
    expect(s.defaultBufferSeconds, 30);
    expect(File('${store.file.path}.bad').existsSync(), isTrue);
  });

  group('Steam achievement settings', () {
    test(
        'steamId64/steamWebApiKey default to empty, clipSteamAchievements '
        'defaults to true', () {
      final s = AppSettings();
      expect(s.steamId64, '');
      expect(s.steamWebApiKey, '');
      expect(s.clipSteamAchievements, isTrue);
    });

    test('round-trip through toJson/fromJson', () {
      final s = AppSettings(
        steamId64: '76561197960287930',
        steamWebApiKey: 'ABCDEF0123456789',
        clipSteamAchievements: false,
      );
      final loaded = AppSettings.fromJson(s.toJson());
      expect(loaded.steamId64, '76561197960287930');
      expect(loaded.steamWebApiKey, 'ABCDEF0123456789');
      expect(loaded.clipSteamAchievements, isFalse);
    });

    test('round-trip through the settings store', () async {
      final store = SettingsStore(tmp);
      await store.save(AppSettings(
        steamId64: '76561197960287930',
        steamWebApiKey: 'ABCDEF0123456789',
      ));
      final loaded = await store.load();
      expect(loaded.steamId64, '76561197960287930');
      expect(loaded.steamWebApiKey, 'ABCDEF0123456789');
    });

    test(
        'a settings file predating this feature (absent keys) falls back to '
        'empty credentials and clipSteamAchievements true', () {
      final j = AppSettings().toJson()
        ..remove('steamId64')
        ..remove('steamWebApiKey')
        ..remove('clipSteamAchievements');
      final loaded = AppSettings.fromJson(j);
      expect(loaded.steamId64, '');
      expect(loaded.steamWebApiKey, '');
      expect(loaded.clipSteamAchievements, isTrue);
    });
  });

  test('save creates the directory if missing', () async {
    final store = SettingsStore(Directory('${tmp.path}/nested/dir'));
    await store.save(AppSettings());
    expect(store.file.existsSync(), isTrue);
    // valid JSON on disk
    jsonDecode(store.file.readAsStringSync());
  });
  test('concurrent saves never publish a torn file — last snapshot wins',
      () async {
    final store = SettingsStore(tmp);
    // Unserialized, these all truncate/write the SAME .tmp path at once —
    // the bug this pins is a rename publishing another writer's
    // half-written JSON (which load() then "recovers" to defaults).
    final futures = <Future<void>>[
      for (var i = 1; i <= 20; i++)
        store.save(AppSettings(defaultBufferSeconds: i)),
    ];
    await Future.wait(futures);

    final loaded = await store.load();
    // Valid JSON (load didn't fall back to defaults via the corrupt-file
    // path — 30 is the default, so any 1..20 value proves a real read)
    // and specifically the LAST queued snapshot.
    expect(loaded.defaultBufferSeconds, 20);
    expect(File('${store.file.path}.bad').existsSync(), isFalse);
  });

  test('save snapshots state at call time, not at queue-drain time',
      () async {
    final store = SettingsStore(tmp);
    final s = AppSettings(defaultBufferSeconds: 15);
    final first = store.save(s);
    // Mutate AFTER the first save call but before its write completes —
    // the first snapshot must still be 15; the second save persists 60.
    s.defaultBufferSeconds = 60;
    await first;
    await store.save(s);
    expect((await store.load()).defaultBufferSeconds, 60);
  });

}
