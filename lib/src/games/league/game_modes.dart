/// League game-mode knowledge, in one place.
///
/// Riot reports an internal mode CODE (`gamestats.gameMode`): "CLASSIC",
/// "CHERRY", "KIWI"… Rewind stores that RAW code and turns it into something
/// human at DISPLAY time — deliberately, and the reason matters:
///
/// The friendly name used to be resolved in the watcher and the *result*
/// persisted into matches.json. That froze it. When ARAM Mayhem ("KIWI",
/// verified live 2026-07-16) turned out to be unmapped, every match already
/// recorded was stuck showing "Kiwi" forever, and the fix could only ever help
/// future matches. Riot ships new modes constantly, so that would recur every
/// single time. Mapping at render instead means adding one entry below fixes
/// past AND future matches at once.
library;

/// Modes where the ORDER/CHAOS `team` field is a genuine two-team split, so
/// "your team vs enemies" is meaningful.
///
/// Arena (CHERRY) is NOT one: verified live 2026-07-15, its team field buckets
/// an 18-player game into an arbitrary 12/6, nowhere near the real duos, which
/// the Live Client Data API doesn't expose at all. Anything not listed here is
/// rendered as one flat champion list rather than inventing teammates.
const _twoTeamModes = {
  'CLASSIC', // Summoner's Rift 5v5
  'ARAM',
  'KIWI', // ARAM Mayhem — a 5v5 ARAM variant on the Howling Abyss
  'URF',
  'ARURF',
  'ONEFORALL',
  'ULTBOOK',
  'NEXUSBLITZ',
  'TUTORIAL',
  'PRACTICETOOL',
};

/// Internal code → the name a player would recognise.
const _friendlyNames = {
  'CLASSIC': "Summoner's Rift",
  'ARAM': 'ARAM',
  'KIWI': 'ARAM Mayhem',
  'CHERRY': 'Arena',
  'URF': 'URF',
  'ARURF': 'ARURF',
  'NEXUSBLITZ': 'Nexus Blitz',
  'ONEFORALL': 'One for All',
  'ULTBOOK': 'Ultimate Spellbook',
  'TUTORIAL': 'Tutorial',
  'PRACTICETOOL': 'Practice Tool',
};

/// Whether [rawMode] is a real two-team mode. Takes the RAW code.
bool isTwoTeamLeagueMode(String? rawMode) =>
    rawMode != null && _twoTeamModes.contains(rawMode.toUpperCase());

/// The display name for a stored mode value.
///
/// Tolerant by design, because it is fed both shapes:
///  * a raw code from the API ("KIWI") — what we store now;
///  * a value persisted by an older build, which was ALREADY friendly
///    ("Arena") or was that build's title-cased fallback for a code it didn't
///    know ("Kiwi").
///
/// Matching case-insensitively against the code table handles all three: an
/// old "Kiwi" row normalises to "KIWI" and finally renders as "ARAM Mayhem",
/// while an old "Arena" row matches nothing (its code is CHERRY) and is
/// returned untouched. Unknown codes fall back to title case *here*, so they
/// are never frozen into storage and start rendering properly the moment the
/// mode is added to [_friendlyNames].
String? friendlyLeagueGameMode(String? value) {
  final v = value?.trim();
  if (v == null || v.isEmpty) return null;
  final known = _friendlyNames[v.toUpperCase()];
  if (known != null) return known;
  // Already-friendly text from an older build (e.g. "Summoner's Rift") — or a
  // mode Riot shipped that we haven't mapped yet.
  if (v.contains(' ') || v != v.toUpperCase()) return v;
  return '${v[0]}${v.substring(1).toLowerCase()}';
}
