/// Which pane the Shell's content area shows — a plain closed value type, no
/// router package (see docs/superpowers/specs/2026-07-13-game-centric-redesign
/// .md §1/§4 T3). The Player remains a pushed full-screen route since it's
/// modal playback, not a destination.
sealed class ShellDestination {
  const ShellDestination();
}

/// The cross-game clip library (Desktop clips included).
class AllClipsDestination extends ShellDestination {
  const AllClipsDestination();

  @override
  bool operator ==(Object other) => other is AllClipsDestination;

  @override
  int get hashCode => (AllClipsDestination).hashCode;
}

/// A single game's hub (`game_hub_screen.dart`, T4): header stats,
/// integration status, a capture-settings summary card (tap to edit on
/// Settings), and this game's scoped clip list.
class GameDestination extends ShellDestination {
  final String gameId;

  const GameDestination(this.gameId);

  @override
  bool operator ==(Object other) =>
      other is GameDestination && other.gameId == gameId;

  @override
  int get hashCode => Object.hash(GameDestination, gameId);
}

/// The Supported Games catalog (built in T5; a placeholder pane until then).
class SupportedGamesDestination extends ShellDestination {
  const SupportedGamesDestination();

  @override
  bool operator ==(Object other) => other is SupportedGamesDestination;

  @override
  int get hashCode => (SupportedGamesDestination).hashCode;
}

/// The app's settings, embedded as a destination.
class SettingsDestination extends ShellDestination {
  /// When set, Settings opens directly on this game's MY GAMES page instead
  /// of the default Capture page — the game hub's summary card sets this so
  /// tapping it jumps straight to "this game's overrides" (`SettingsScreen.
  /// initialGameId`). Null for every other entry point (the rail's Settings
  /// item, the recorder deck's "Custom…" path), which always open plain
  /// Settings.
  final String? initialGameId;

  const SettingsDestination({this.initialGameId});

  @override
  bool operator ==(Object other) =>
      other is SettingsDestination && other.initialGameId == initialGameId;

  @override
  int get hashCode => Object.hash(SettingsDestination, initialGameId);
}
