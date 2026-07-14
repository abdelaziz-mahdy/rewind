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

/// A single game's hub. Until the real Game Hub (T4) lands, the Shell renders
/// this as the All Clips list pre-filtered to [gameId] — see the T3 task
/// brief's "cheap interim" note.
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
  const SettingsDestination();

  @override
  bool operator ==(Object other) => other is SettingsDestination;

  @override
  int get hashCode => (SettingsDestination).hashCode;
}
