import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
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
      expect(d.captureMaxHeight, isNull); // source
      expect(d.audioMode, AudioMode.all);

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

  test('corrupt file is backed up and defaults returned', () async {
    final store = SettingsStore(tmp);
    store.file.writeAsStringSync('{not json');
    final s = await store.load();
    expect(s.defaultBufferSeconds, 30);
    expect(File('${store.file.path}.bad').existsSync(), isTrue);
  });

  test('save creates the directory if missing', () async {
    final store = SettingsStore(Directory('${tmp.path}/nested/dir'));
    await store.save(AppSettings());
    expect(store.file.existsSync(), isTrue);
    // valid JSON on disk
    jsonDecode(store.file.readAsStringSync());
  });
}
