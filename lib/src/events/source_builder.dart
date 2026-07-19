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
///
/// The `LeagueEventWatcher()` literal here (and its twin in
/// `game_registry.dart`'s default constructor) stays hand-written rather
/// than growing a `watcherFactory` field on `GameDescriptor` (Task 21): that
/// field would pull `events/league_event_watcher.dart` into the `games/`
/// layer opposite `game_descriptor.dart`'s existing `events/game_catalog.
/// dart` dependency, for the sake of deduplicating exactly one line in two
/// places. Revisit if/when a second vendor-API integration lands — the
/// `GameEventSource` interface (ARCHITECTURE.md) is already the seam for it.
List<GameEventSource> buildSources(AppSettings settings) {
  final sources = <GameEventSource>[LeagueEventWatcher()];
  final seenGameIds = {for (final s in sources) s.gameId};

  // ONE shared, tick-cached lister for every process watcher: without it,
  // each of the dozen+ sources spawns its own `ps`/`tasklist` every
  // supervision tick, forever.
  final lister = CachingProcessLister(const SystemProcessLister());

  for (final g in popularGamesCatalog) {
    if (!seenGameIds.add(g.gameId)) continue;
    sources.add(ProcessWatcherSource(
      gameId: g.gameId,
      displayName: g.displayName,
      processMatch: g.processMatch,
      lister: lister,
      countsAsPlaying: g.countsAsPlaying,
    ));
  }

  for (final cfg in settings.allConfigs) {
    final match = cfg.processMatch;
    if (match == null) continue;
    if (!seenGameIds.add(cfg.gameId)) continue;
    sources.add(ProcessWatcherSource(
      gameId: cfg.gameId,
      displayName: cfg.displayName ?? cfg.gameId,
      processMatch: match,
      lister: lister,
    ));
  }

  return sources;
}
