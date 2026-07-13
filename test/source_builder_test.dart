import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_catalog.dart';
import 'package:rewind/src/events/league_event_watcher.dart';
import 'package:rewind/src/events/process_watcher_source.dart';
import 'package:rewind/src/events/source_builder.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';

void main() {
  group('buildSources', () {
    test('includes a LeagueEventWatcher for league_of_legends', () {
      final sources = buildSources(AppSettings());
      final league = sources.whereType<LeagueEventWatcher>();
      expect(league, hasLength(1));
      expect(league.single.gameId, 'league_of_legends');
    });

    test(
        'includes one ProcessWatcherSource per catalog entry, with '
        'matching gameId/displayName/processMatch', () {
      final sources = buildSources(AppSettings());
      final processSources = {
        for (final s in sources.whereType<ProcessWatcherSource>()) s.gameId: s
      };

      for (final g in popularGamesCatalog) {
        final s = processSources[g.gameId];
        expect(s, isNotNull, reason: 'missing source for ${g.gameId}');
        expect(s!.displayName, g.displayName);
        expect(s.processMatch, g.processMatch);
      }
    });

    test(
        'total source count is League + catalog when no user config has '
        'a processMatch', () {
      final sources = buildSources(AppSettings());
      expect(sources.length, 1 + popularGamesCatalog.length);
    });

    test(
        'adds a source for a user-configured per-game processMatch not '
        'already covered by the catalog', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(
          gameId: 'app:my_custom_game',
          processMatch: 'MyCustomGame',
        ));

      final sources = buildSources(settings);
      final custom = sources
          .whereType<ProcessWatcherSource>()
          .where((s) => s.gameId == 'app:my_custom_game');

      expect(custom, hasLength(1));
      expect(custom.single.processMatch, 'MyCustomGame');
      expect(sources.length, 1 + popularGamesCatalog.length + 1);
    });

    test(
        'ignores a per-game config with no processMatch (null = no '
        'auto-detection)', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(gameId: 'league_of_legends'));

      final sources = buildSources(settings);
      expect(sources.length, 1 + popularGamesCatalog.length);
    });

    test(
        'does not duplicate a source when a user config reuses a '
        'catalog/League gameId', () {
      final settings = AppSettings()
        ..setConfig(GameConfig(
          gameId: 'league_of_legends',
          processMatch: 'League of Legends.exe',
        ))
        ..setConfig(GameConfig(
          gameId: popularGamesCatalog.first.gameId,
          processMatch: 'something-else',
        ));

      final sources = buildSources(settings);
      final gameIds = sources.map((s) => s.gameId).toList();
      expect(gameIds.toSet().length, gameIds.length,
          reason: 'duplicate gameId in built sources: $gameIds');
      expect(sources.length, 1 + popularGamesCatalog.length);
    });

    test('all built sources have unique gameIds', () {
      final sources = buildSources(AppSettings());
      final gameIds = sources.map((s) => s.gameId).toList();
      expect(gameIds.toSet().length, gameIds.length);
    });
  });
}
