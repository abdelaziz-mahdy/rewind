import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/obs/app_info.dart';
import 'package:rewind/src/ui/capture_app_match.dart';

void main() {
  group('appMatchesProcess', () {
    test('matches via a substring of the app name', () {
      const app =
          AppInfo(bundleId: 'com.example.app', name: 'My CS2 Overlay', pid: 1);
      expect(appMatchesProcess(app, 'cs2'), isTrue);
    });

    test('matches via a substring of the bundle id', () {
      const app =
          AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 1);
      expect(appMatchesProcess(app, 'cs2'), isTrue);
    });

    test('is case-insensitive', () {
      const app =
          AppInfo(bundleId: 'com.example.app', name: 'VALORANT', pid: 1);
      expect(appMatchesProcess(app, 'valorant'), isTrue);
    });

    test('false when neither name nor bundle id contains the needle', () {
      const app = AppInfo(bundleId: 'com.apple.safari', name: 'Safari', pid: 1);
      expect(appMatchesProcess(app, 'cs2'), isFalse);
    });
  });

  group('findRunningApp', () {
    const apps = [
      AppInfo(bundleId: 'com.apple.safari', name: 'Safari', pid: 1),
      AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 2),
    ];

    test('returns the first matching app', () {
      expect(findRunningApp('cs2', apps)?.bundleId, 'com.valve.cs2');
    });

    test('returns null when nothing matches', () {
      expect(findRunningApp('dota2', apps), isNull);
    });
  });

  group('matchingCatalogGame', () {
    test('finds the catalog entry whose processMatch matches the app', () {
      const app =
          AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 1);
      final match = matchingCatalogGame(app);
      expect(match?.gameId, 'app:cs2');
    });

    test('null when no catalog entry matches', () {
      const app =
          AppInfo(bundleId: 'com.example.discord', name: 'Discord', pid: 1);
      expect(matchingCatalogGame(app), isNull);
    });
  });

  group('slugify', () {
    test('lowercases and collapses non-alphanumerics to underscores', () {
      expect(slugify('OBS Studio'), 'obs_studio');
    });

    test('trims leading/trailing underscores', () {
      expect(slugify('  Discord!! '), 'discord');
    });

    test('collapses runs of separators into a single underscore', () {
      expect(slugify('Riot---Client'), 'riot_client');
    });

    test('empty for a symbols-only input', () {
      expect(slugify('***'), '');
    });
  });

  group('gameIdForApp', () {
    test('reuses the catalog gameId for a catalog-matched app — no duplicate',
        () {
      const app =
          AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 1);
      expect(gameIdForApp(app), 'app:cs2');
    });

    test('mints a fresh app:<slug> id for a non-catalog app', () {
      const app = AppInfo(bundleId: 'com.hnc.Discord', name: 'Discord', pid: 1);
      expect(gameIdForApp(app), 'app:discord');
    });

    test('falls back to the bundle id slug when the name has no letters/digits',
        () {
      const app = AppInfo(bundleId: 'com.example.app42', name: '★★★', pid: 1);
      expect(gameIdForApp(app), 'app:com_example_app42');
    });
  });

  group('partitionCapturableApps', () {
    test('games = catalog matches + Wine exes (empty bundleId), sorted', () {
      const apps = [
        AppInfo(bundleId: 'com.apple.Terminal', name: 'Terminal', pid: 1),
        AppInfo(bundleId: '', name: 'PenguinHotel-Win64-Shipping', pid: 2),
        AppInfo(bundleId: 'com.valve.cs2', name: 'Counter-Strike 2', pid: 3),
        AppInfo(bundleId: 'com.hnc.Discord', name: 'Discord', pid: 4),
        AppInfo(bundleId: '', name: 'anotherwine', pid: 5),
      ];
      final grouped = partitionCapturableApps(apps);
      expect(grouped.games.map((a) => a.name).toList(),
          ['anotherwine', 'Counter-Strike 2', 'PenguinHotel-Win64-Shipping']);
      expect(
          grouped.others.map((a) => a.name).toList(), ['Discord', 'Terminal']);
    });

    test('empty input yields two empty groups', () {
      final grouped = partitionCapturableApps(const []);
      expect(grouped.games, isEmpty);
      expect(grouped.others, isEmpty);
    });
  });
}
