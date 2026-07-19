import '../settings/app_settings.dart';
import 'game_catalog.dart';
import 'game_event_source.dart';
import 'league_event_watcher.dart';
import 'process_watcher_source.dart';
import 'steam_achievement_watcher.dart';

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
///
/// Steam credentials-change wiring: `SteamAchievementWatcher` holds a LIVE
/// reference to [settings] (not a snapshot), so an edited API key/Steam ID
/// or a flipped `clipSteamAchievements` toggle on an ALREADY-running watcher
/// takes effect on its very next poll with no rebuild at all. What this
/// function's credential gate below actually controls is narrower: going
/// from "no credentials" (watcher doesn't exist yet) to "credentials set for
/// the first time" needs a NEW instance, which only happens when this
/// function runs again. `main.dart` covers that via the existing
/// `registry.addNewSources(buildSources(s))` call already made on every
/// settings change (see its doc) — `main.dart` additionally re-scans
/// `registry.sources` for a `SteamAchievementWatcher` after that call and
/// starts it if it's newly present, since (per [SteamAchievementWatcher.
/// isGameRunning]'s doc) `GameRegistry`'s normal activation tick never
/// starts this source itself. The smallest-honest-wiring gap this leaves:
/// clearing credentials back to empty doesn't tear the instance down (no
/// source removal exists in `GameRegistry` at all, by design — see
/// `addNewSources`' doc) — it just idles (its own live-settings check
/// no-ops every poll) until the next full restart drops it from a fresh
/// [buildSources] call. That's consistent with how every other
/// settings-driven source already behaves here.
List<GameEventSource> buildSources(AppSettings settings) {
  final sources = <GameEventSource>[LeagueEventWatcher()];
  if (settings.steamId64.isNotEmpty && settings.steamWebApiKey.isNotEmpty) {
    sources.add(SteamAchievementWatcher(settings: settings));
  }
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
