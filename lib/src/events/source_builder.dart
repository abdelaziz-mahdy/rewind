import '../settings/app_settings.dart';
import 'game_catalog.dart';
import 'game_event_source.dart';
import 'league_event_watcher.dart';
import 'process_watcher_source.dart';

/// Builds the full list of [GameEventSource]s [GameRegistry] should
/// supervise: the vendor-API League integration, one generic
/// process-detection source per [popularGamesCatalog] entry, and one more
/// per user-configured [GameConfig.processMatch] override.
///
/// A pure function of [settings] — no side effects, no engine/registry
/// access — so `main.dart`'s startup wiring stays thin and this composition
/// is unit-testable without booting the app.
///
/// Sources are deduped by [GameEventSource.gameId] in the order listed
/// above (League, then catalog, then user config): if a user's per-game
/// config happens to share a gameId already covered by League or the
/// catalog, it's skipped here rather than adding a second
/// [ProcessWatcherSource] that would fight the first over the same id in
/// [GameRegistry]'s active-set bookkeeping.
List<GameEventSource> buildSources(AppSettings settings) {
  final sources = <GameEventSource>[LeagueEventWatcher()];
  final seenGameIds = {for (final s in sources) s.gameId};

  for (final g in popularGamesCatalog) {
    if (!seenGameIds.add(g.gameId)) continue;
    sources.add(ProcessWatcherSource(
      gameId: g.gameId,
      displayName: g.displayName,
      processMatch: g.processMatch,
    ));
  }

  for (final cfg in settings.allConfigs) {
    final match = cfg.processMatch;
    if (match == null) continue;
    if (!seenGameIds.add(cfg.gameId)) continue;
    // GameConfig has no separate display-name field (the Per-game settings
    // list itself just shows the gameId, see settings_screen.dart) — the
    // gameId doubles as the display name here for the same reason.
    sources.add(ProcessWatcherSource(
      gameId: cfg.gameId,
      displayName: cfg.gameId,
      processMatch: match,
    ));
  }

  return sources;
}
