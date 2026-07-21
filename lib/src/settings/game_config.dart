import '../events/game_event.dart';

/// Per-game configuration. Each game can have its own replay-buffer length,
/// its own set of auto-clipped events, and whether auto-clipping is on.
class GameConfig {
  final String gameId;

  /// Replay-buffer length in seconds for this game (e.g. 30 or 60).
  int bufferSeconds;

  /// How long to keep recording after the LAST auto-clip-triggering event
  /// before saving (quiet-time debounce — see `ClipCoordinator.burstQuiet`'s
  /// doc). A follow-up event inside this window extends the same clip
  /// rather than starting a new one. Default 5 s.
  int postEventSeconds;

  /// Whether to auto-clip on detected events (vs. hotkey-only).
  bool autoClip;

  /// Whether to record the ENTIRE play session to one continuous file while
  /// this game is running, in ADDITION to the rolling replay buffer and its
  /// event/hotkey clips (the buffer keeps running; both coexist — the shim's
  /// continuous recording shares the buffer's encoders, see
  /// `rewind_start_recording`). Off by default: full sessions are large, and
  /// obey the same storage retention (`maxStorageGb`/`maxClipAgeDays`) as
  /// clips. Started/stopped by `ClipCoordinator` on game activation/exit.
  bool recordFullSession;

  /// Event kinds to auto-clip for this game.
  Set<GameEventKind> enabledEvents;

  /// Case-insensitive substring to match against running process names for
  /// auto-detecting this entry (see `ProcessWatcherSource.processMatch`).
  /// Null means no auto-detection: this config is only ever applied when
  /// some other source (a vendor-API watcher, or a catalog entry sharing
  /// this [gameId]) reports the game active. Set by the capture-source
  /// picker when the user picks an app (see `recorder_cluster.dart`'s
  /// `_pickApp` and `lib/src/events/source_builder.dart`).
  String? processMatch;

  /// User-chosen display-name override for this game (Task 28's rename
  /// feature) — either the picked app's real name ("PenguinHotel-Win64-
  /// Shipping") whose casing the `app:<slug>` gameId loses, or an explicit
  /// rename the user typed for ANY renameable game, catalog games included
  /// (e.g. "Counter-Strike 2" → "CS2 ranked"). Null means no override (the
  /// derived catalog/descriptor/title-case name wins) — a cleared rename
  /// field writes null, never `''`, so this round-trips through JSON
  /// exactly like "never set". ALWAYS null for a descriptor-registered game
  /// (League, Marvel Rivals — see `game_catalog.dart`'s `isGameRenameable`
  /// doc for why those aren't renameable in v1); `displayNameFor` ignores
  /// this field for such a game even if it's somehow non-null. Consulted by
  /// `displayNameFor` via `registerCustomDisplayNames`, and directly by
  /// `game_directory.dart`'s `buildGameDirectory` for `GameEntry.
  /// displayName`.
  String? displayName;

  /// Absolute path to this game's app icon (an `.icns` bundle icon, the
  /// same [AppInfo.iconPath] the capture-source picker already reads via
  /// `icns.dart`), captured once from a real running-app match — either a
  /// manual pick (`_SourceLine._pickApp`) or an auto-detection match
  /// (`ClipCoordinator._autoSwitchCaptureFor`) — and persisted here so the
  /// rail can show a real logo (`GameTileAvatar`) even when the game isn't
  /// currently running (an `AppInfo` only exists while its process is
  /// enumerable). Null for games never matched to a running app, and
  /// ALWAYS null for Wine/CrossOver games (see `AppInfo.iconPath`'s doc) —
  /// `GameTileAvatar` falls back to the monogram either way.
  String? iconPath;

  GameConfig({
    required this.gameId,
    this.bufferSeconds = 30,
    this.postEventSeconds = 5,
    this.autoClip = true,
    this.recordFullSession = false,
    Set<GameEventKind>? enabledEvents,
    this.processMatch,
    this.displayName,
    this.iconPath,
  }) : enabledEvents = enabledEvents ??
            {
              GameEventKind.manual,
              GameEventKind.kill,
              GameEventKind.doubleKill,
              GameEventKind.tripleKill,
              GameEventKind.quadraKill,
              GameEventKind.pentaKill,
              GameEventKind.ace,
              // Steam achievements are gated by their OWN global toggle
              // (`AppSettings.clipSteamAchievements`) before
              // `SteamAchievementWatcher` ever emits one — this default just
              // makes sure the event PASSES this per-game gate once it
              // arrives, including for a game with no config row yet (e.g.
              // the `steam:<appid>` fallback for an unrecognized Steam
              // title), without the coordinator special-casing Steam at all.
              GameEventKind.achievement,
            };

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'bufferSeconds': bufferSeconds,
        'postEventSeconds': postEventSeconds,
        'autoClip': autoClip,
        'recordFullSession': recordFullSession,
        'enabledEvents': enabledEvents.map((e) => e.name).toList(),
        'processMatch': processMatch,
        'displayName': displayName,
        'iconPath': iconPath,
      };

  factory GameConfig.fromJson(Map<String, dynamic> j) => GameConfig(
        gameId: j['gameId'] as String,
        bufferSeconds: j['bufferSeconds'] as int? ?? 30,
        // Absent key (settings file predating this feature) → the 5 s
        // default, same fallback the constructor already uses.
        postEventSeconds: j['postEventSeconds'] as int? ?? 5,
        autoClip: j['autoClip'] as bool? ?? true,
        // Absent key (settings predating this feature) → off.
        recordFullSession: j['recordFullSession'] as bool? ?? false,
        enabledEvents: ((j['enabledEvents'] as List?) ?? const [])
            .map((n) => GameEventKind.values.firstWhere((e) => e.name == n,
                orElse: () => GameEventKind.other))
            .toSet(),
        processMatch: j['processMatch'] as String?,
        displayName: j['displayName'] as String?,
        iconPath: j['iconPath'] as String?,
      );
}
