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
