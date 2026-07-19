import 'package:flutter/widgets.dart';

import '../clip/match_stats.dart';
import 'game_descriptor.dart';
import 'league/ddragon.dart';

/// Per-game presentation for the match drill-down (`MatchClipsScreen`): the
/// summary band, collapsible extras (e.g. League's roster disclosure), and
/// footnote caption are all game-specific, so each integration owns its own
/// rendering behind this seam rather than the generic screen importing
/// per-game widgets directly ("each game has its own impl and handling" —
/// the maintainer's stated direction). A game with no impl (see
/// [matchPresentationFor]) simply gets none of these — the bare session
/// frame (app bar + clip grid) is a safe default for a game nobody has
/// written presentation for yet.
abstract class MatchPresentation {
  const MatchPresentation();

  /// The band area above the clip grid (League: champion portrait, headline,
  /// K/D/A/CS/WS line, item build). Null renders nothing. Only ever called
  /// with non-null stats — see [footnote] for the one call that also covers
  /// the no-stats case.
  Widget? buildSummary(BuildContext context, MatchStats stats);

  /// Collapsible extras below the footnote (League: the roster disclosure).
  /// Null renders nothing. Only ever called with non-null stats.
  Widget? buildExtras(BuildContext context, MatchStats stats);

  /// The caption under the band, or null for none. Takes the whole
  /// (possibly null) [stats] deliberately — unlike [buildSummary]/
  /// [buildExtras], whether a footnote makes sense AT ALL can depend on
  /// stats existing in the first place (see e90a86f: a process-detected
  /// game with no live-tracked stats must not claim "kills counted from the
  /// live game").
  String? footnote(MatchStats? stats);
}

/// Resolves the presentation for a game, or null for a game with no
/// per-game impl (the screen then renders the bare frame) — delegates to the
/// game's [GameDescriptor] (Task 21's registry) rather than hardcoding
/// League's ids here. [ddragon] is threaded straight into the League impl's
/// constructor when the caller has one wired up (null renders the
/// monogram/blank art fallbacks, same as today).
MatchPresentation? matchPresentationFor(String gameId, {DDragon? ddragon}) =>
    descriptorFor(gameId).presentationFactory(ddragon: ddragon);
