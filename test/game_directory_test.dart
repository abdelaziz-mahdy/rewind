import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/settings/game_config.dart';
import 'package:rewind/src/ui/game_directory.dart';

void main() {
  Clip clip(String gameId, {int sizeBytes = 1000, DateTime? createdAt}) => Clip(
        path: '/tmp/$gameId-${createdAt?.millisecondsSinceEpoch ?? 0}.mp4',
        gameId: gameId,
        event: GameEventKind.manual,
        createdAt: createdAt ?? DateTime(2026, 1, 1),
        sizeBytes: sizeBytes,
      );

  GameEntry byId(List<GameEntry> entries, String gameId) =>
      entries.firstWhere((e) => e.gameId == gameId);

  test('desktop is always present and pinned last', () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'app:cs2'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [clip('app:cs2')],
      activeIds: {},
    );

    expect(entries.last.gameId, 'desktop');
    expect(entries.map((e) => e.gameId), contains('desktop'));
  });

  test('desktop is pinned last even when it would otherwise sort earlier', () {
    // "Desktop" alphabetically precedes "Counter-Strike 2", but it must
    // still land last: it's a pinned pseudo-game, not a sorted entry.
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'app:cs2'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {},
    );

    expect(entries.map((e) => e.gameId).toList(), ['app:cs2', 'desktop']);
  });

  test(
      'league vendor config + catalog process-watch activity merge into one '
      'row with both detection methods', () {
    final settings = AppSettings();
    // Only the vendor gameId is configured...
    settings.setConfig(GameConfig(gameId: 'league_of_legends'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      // ...while only the catalog gameId is reported active.
      activeIds: {'app:league_of_legends'},
    );

    final leagueRows =
        entries.where((e) => e.gameId.contains('league')).toList();
    expect(leagueRows, hasLength(1));

    final league = leagueRows.single;
    expect(league.gameId, 'league_of_legends');
    expect(
      league.detection,
      {DetectionMethod.liveClientApi, DetectionMethod.processWatch},
    );
    expect(league.active, isTrue);
    // Only the catalog (client-open) half fired: the row is active but NOT
    // vendor-active — the hub must not claim an in-progress match.
    expect(league.vendorActive, isFalse);
    expect(league.processMatch, 'LeagueClientUx');
  });

  test('a game with clips but no config and never active still appears', () {
    final settings = AppSettings();
    final entries = buildGameDirectory(
      settings: settings,
      clips: [clip('some_clip_only_game')],
      activeIds: {},
    );

    final entry = byId(entries, 'some_clip_only_game');
    expect(entry.clipCount, 1);
    expect(entry.active, isFalse);
  });

  test('a configured game with no clips yet still appears with zero stats', () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'app:cs2'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {},
    );

    final entry = byId(entries, 'app:cs2');
    expect(entry.clipCount, 0);
    expect(entry.totalSizeBytes, 0);
    expect(entry.lastClipAt, isNull);
    expect(entry.detection, {DetectionMethod.processWatch});
    expect(entry.processMatch, 'cs2');
  });

  test(
      'a live-detected game with no config and no clips appears as active '
      'via process-watch detection', () {
    final settings = AppSettings();
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {'app:valorant'},
    );

    final entry = byId(entries, 'app:valorant');
    expect(entry.active, isTrue);
    expect(entry.clipCount, 0);
    expect(entry.detection, {DetectionMethod.processWatch});
  });

  test('stats are derived purely from the clip list: count, size, last age',
      () {
    final settings = AppSettings();
    final older = DateTime(2026, 1, 1);
    final newer = DateTime(2026, 3, 1);
    final entries = buildGameDirectory(
      settings: settings,
      clips: [
        clip('app:cs2', sizeBytes: 500, createdAt: older),
        clip('app:cs2', sizeBytes: 1500, createdAt: newer),
      ],
      activeIds: {},
    );

    final entry = byId(entries, 'app:cs2');
    expect(entry.clipCount, 2);
    expect(entry.totalSizeBytes, 2000);
    expect(entry.lastClipAt, newer);
  });

  test('active games sort before inactive games, alphabetically within each',
      () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'app:cs2'));
    settings.setConfig(GameConfig(gameId: 'app:dota2'));
    settings.setConfig(GameConfig(gameId: 'app:valorant'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      // Dota 2 and VALORANT are active; Counter-Strike 2 is not.
      activeIds: {'app:dota2', 'app:valorant'},
    );

    final ids = entries.map((e) => e.gameId).toList();
    // Active first (alphabetical: Dota 2 < VALORANT), then inactive, then
    // desktop pinned last.
    expect(ids, ['app:dota2', 'app:valorant', 'app:cs2', 'desktop']);
  });

  test(
      'desktop clips (manual, no game detected) are counted on the desktop entry',
      () {
    final settings = AppSettings();
    final entries = buildGameDirectory(
      settings: settings,
      clips: [clip('desktop'), clip('desktop')],
      activeIds: {},
    );

    final desktop = byId(entries, 'desktop');
    expect(desktop.clipCount, 2);
    expect(desktop.detection, {DetectionMethod.manual});
  });

  test(
      'an unrecognized configured gameId with no processMatch has no '
      'detection method (no invented data)', () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'totally_custom_game'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {},
    );

    final entry = byId(entries, 'totally_custom_game');
    expect(entry.detection, isEmpty);
    expect(entry.processMatch, isNull);
  });

  test('a GameConfig.iconPath is surfaced on its entry for the rail logo', () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(
        gameId: 'app:cs2', iconPath: '/Applications/CS2.app/icon.icns'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {},
    );

    expect(
        byId(entries, 'app:cs2').iconPath, '/Applications/CS2.app/icon.icns');
  });

  test('no iconPath means null, not an invented path', () {
    final settings = AppSettings();
    settings.setConfig(GameConfig(gameId: 'app:cs2'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {},
    );

    expect(byId(entries, 'app:cs2').iconPath, isNull);
  });

  test(
      'League NEVER surfaces an iconPath even if one was persisted (its app '
      'icon is Riot\'s official logo — Riot policy forbids using it, unlike '
      'champion/item art)', () {
    final settings = AppSettings();
    // Simulates data written by a pre-fix version of Rewind — must still
    // never render, not just never be captured going forward.
    settings.setConfig(GameConfig(
        gameId: 'app:league_of_legends',
        iconPath: '/Applications/League of Legends.app/icon.icns'));
    final entries = buildGameDirectory(
      settings: settings,
      clips: [],
      activeIds: {'app:league_of_legends'},
    );

    expect(byId(entries, 'league_of_legends').iconPath, isNull);
  });
}
