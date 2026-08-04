import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/events/source_builder.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/game_directory.dart';

/// Removing a game is two decisions that used to be one: forget what Rewind
/// learned about it (config, name, icon) AND stop watching it. Dropping only
/// the config is not enough — every catalog title is watched whether or not
/// it has a config row, so a removed game reappeared the moment it ran.
void main() {
  Clip clip(String gameId, {int sizeBytes = 1000}) => Clip(
        path: '/tmp/$gameId.mp4',
        gameId: gameId,
        event: GameEventKind.manual,
        createdAt: DateTime(2026, 8, 1),
        sizeBytes: sizeBytes,
      );

  group('detection', () {
    test('a removed catalog game gets no process watcher', () {
      final settings = AppSettings();
      final watchedBefore = {for (final s in buildSources(settings)) s.gameId};
      expect(watchedBefore, contains('app:cs2'));

      settings.ignoredGameIds.add('app:cs2');

      final watchedAfter = {for (final s in buildSources(settings)) s.gameId};
      expect(watchedAfter, isNot(contains('app:cs2')));
      // Everything else keeps its watcher.
      expect(watchedAfter.length, watchedBefore.length - 1);
    });

    test("a removed game's vendor watcher goes too, not just process watch",
        () {
      final settings = AppSettings()..ignoredGameIds.add('league_of_legends');
      final watched = {for (final s in buildSources(settings)) s.gameId};
      expect(watched, isNot(contains('league_of_legends')));
    });

    test('a removed user-added game gets no watcher from its own config', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(gameId: 'app:mygame', processMatch: 'MyGame'));
      expect({for (final s in buildSources(settings)) s.gameId},
          contains('app:mygame'));

      settings.ignoredGameIds.add('app:mygame');
      expect({for (final s in buildSources(settings)) s.gameId},
          isNot(contains('app:mygame')));
    });
  });

  group('the game list', () {
    test('a removed game with no clips disappears', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(gameId: 'app:cs2'))
        ..ignoredGameIds.add('app:cs2')
        ..removeConfig('app:cs2');

      final ids = {
        for (final e in buildGameDirectory(
            settings: settings, clips: const [], activeIds: {'app:cs2'}))
          e.gameId,
      };

      // Even while it is RUNNING: removal means removal, and a row that
      // reappeared on launch would read as the removal having failed.
      expect(ids, isNot(contains('app:cs2')));
    });

    test('a removed game that still has clips keeps its row, unwatched', () {
      final settings = AppSettings()..ignoredGameIds.add('app:cs2');

      final entries = buildGameDirectory(
        settings: settings,
        clips: [clip('app:cs2')],
        activeIds: const {},
      );
      final entry = entries.firstWhere((e) => e.gameId == 'app:cs2');

      // The row survives so those clips still have a hub to live in — but it
      // must not claim anything is watching the game.
      expect(entry.clipCount, 1);
      expect(entry.detection, {DetectionMethod.manual});
    });

    test('removing one half of a merged row does not hide it', () {
      // League owns two ids. Remove writes both; a half-removed row would be
      // a state the UI has no way to express.
      final settings = AppSettings()
        ..ignoredGameIds.add('app:league_of_legends');
      final ids = {
        for (final e in buildGameDirectory(
            settings: settings,
            clips: const [],
            activeIds: {'league_of_legends'}))
          e.gameId,
      };
      expect(ids, contains('league_of_legends'));
    });
  });

  group('persistence', () {
    test('removals survive a round trip', () {
      final settings = AppSettings()..ignoredGameIds.addAll({'a', 'b'});
      final back = AppSettings.fromJson(settings.toJson());
      expect(back.ignoredGameIds, {'a', 'b'});
    });

    test('settings written before this existed load as nothing removed', () {
      final json = AppSettings().toJson()..remove('ignoredGameIds');
      expect(AppSettings.fromJson(json).ignoredGameIds, isEmpty);
    });

    test('removeConfig drops the overrides, name and icon together', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(
          gameId: 'app:repo',
          displayName: 'My Name',
          iconPath: '/tmp/wrong.icns',
          bufferSeconds: 90,
        ));

      settings.removeConfig('app:repo');

      expect(settings.allConfigs.where((c) => c.gameId == 'app:repo'), isEmpty);
    });
  });
}
