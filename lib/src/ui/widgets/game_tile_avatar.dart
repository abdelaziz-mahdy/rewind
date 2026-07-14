import 'package:flutter/material.dart';

import '../theme.dart';

/// A squared "logo" stand-in for a game: 1-2 letter initials on a muted,
/// per-game tint (or, for the `desktop` pseudo-game, the desktop icon).
///
/// Rewind ships no real game artwork on purpose: the actual logos/icons are
/// trademarked assets whose license terms don't permit redistribution in a
/// GPLv3 repository (see `docs/COMPLIANCE.md`'s "sanctioned sources only"
/// stance — the same caution that keeps integrations off game memory also
/// keeps this app off games' branded assets). Reading each game's real,
/// OS-installed app icon at runtime (rather than bundling artwork) is a
/// plausible future upgrade, but out of scope here — see docs/superpowers/
/// specs/2026-07-13-game-centric-redesign.md.
///
/// Used at three sizes: 28 px in the left rail, 40 px in the game hub
/// header, 32 px in the Supported Games rows.
class GameTileAvatar extends StatelessWidget {
  final String gameId;
  final String displayName;
  final double size;

  const GameTileAvatar({
    required this.gameId,
    required this.displayName,
    required this.size,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final tokens = context.rewindTokens;
    final radius = BorderRadius.circular(tokens.radiusControl);

    // The manual-capture pseudo-game has no display name worth abbreviating
    // ("Desktop" -> "DE" reads as a typo) and no per-game tint would mean
    // anything, so it gets the desktop icon instead of a monogram.
    if (gameId == 'desktop') {
      return Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: tokens.surfaceRaised,
          borderRadius: radius,
          border: Border.all(color: tokens.hairline),
        ),
        child: Icon(Icons.desktop_windows_outlined,
            size: size * 0.55, color: tokens.textMuted),
      );
    }

    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration:
          BoxDecoration(color: gameTileColor(gameId), borderRadius: radius),
      child: Text(
        gameTileInitials(displayName),
        style: TextStyle(
          color: gameTileTextColor(gameId),
          fontWeight: FontWeight.w800,
          fontSize: size * 0.36,
          letterSpacing: -0.2,
          height: 1,
        ),
      ),
    );
  }
}

/// FNV-1a (32-bit) over [input] — used instead of [Object.hashCode] because
/// `hashCode` is explicitly not guaranteed stable across Dart versions or
/// platforms (VM vs. web), and [gameTileColor]/[gameTileTextColor] need a
/// hue that reproduces identically everywhere the app runs.
int _stableHash(String input) {
  var hash = 0x811c9dc5;
  for (final unit in input.codeUnits) {
    hash = ((hash ^ unit) * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}

/// Minor connector words skipped when picking a multi-word name's two
/// "significant" words — without this, "League of Legends" would monogram
/// as "LO" (League + of) rather than the "LL" (League + Legends) that
/// actually reads as the game's initials.
const _minorWords = {'of', 'the', 'and', 'in', 'at', 'on'};

/// 1-2 uppercase letters standing in for a game's "logo": the first letter
/// of each of the first two *significant* words (connector words like "of"
/// skipped) for a multi-word name ("League of Legends" -> "LL",
/// "Counter-Strike 2" -> "C2"), else the first two letters of a single-word
/// name ("VALORANT" -> "VA"). Pure function of the display name, so it's
/// identical everywhere that name is shown.
String gameTileInitials(String displayName) {
  final words = displayName
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return '';
  if (words.length == 1) {
    final word = words.first;
    return (word.length >= 2 ? word.substring(0, 2) : word).toUpperCase();
  }
  final significant =
      words.where((w) => !_minorWords.contains(w.toLowerCase())).toList();
  final picked = significant.length >= 2 ? significant : words;
  return (picked[0].substring(0, 1) + picked[1].substring(0, 1)).toUpperCase();
}

/// A deterministic per-game tile tint: [gameId] hashes to a hue, held at a
/// fixed low saturation/lightness so every tile reads as a muted dark chip
/// rather than turning the rail/hub/catalog into a rainbow — the same
/// one-accent restraint as the rest of the palette (see docs/superpowers/
/// specs/2026-07-13-game-centric-redesign.md §2).
Color gameTileColor(String gameId) {
  final hue = (_stableHash(gameId) % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.25, 0.22).toColor();
}

/// The monogram's text color: the same hue as [gameTileColor], lifted to a
/// lightness that stays legible against it.
Color gameTileTextColor(String gameId) {
  final hue = (_stableHash(gameId) % 360).toDouble();
  return HSLColor.fromAHSL(1, hue, 0.3, 0.82).toColor();
}
