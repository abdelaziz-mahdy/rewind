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

/// The Supported Games catalog — the auto-detectable titles, their live
/// running/in-library/addable state, and the "Running now" add-any-app
/// section (see `SupportedGamesScreen`).
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

  /// When set, Settings opens directly on this GENERAL sidebar tab (the
  /// `settingsTab:<id>` suffix, e.g. `"Steam"`) instead of the default
  /// Capture page -- onboarding's "Set up Steam achievements" shortcut sets
  /// this so finishing onboarding lands straight on the Steam tab. Null for
  /// every other entry point. Ignored if [initialGameId] is also set (a MY
  /// GAMES page takes precedence -- the two are never set together in
  /// practice).
  final String? initialTab;

  const SettingsDestination({this.initialGameId, this.initialTab});

  @override
  bool operator ==(Object other) =>
      other is SettingsDestination &&
      other.initialGameId == initialGameId &&
      other.initialTab == initialTab;

  @override
  int get hashCode =>
      Object.hash(SettingsDestination, initialGameId, initialTab);
}
