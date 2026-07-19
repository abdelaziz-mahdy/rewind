import 'dart:io';

import 'package:path/path.dart' as p;

/// One Steam account found in a local `loginusers.vdf` -- Steam's own
/// account cache, rewritten on every login/logout of the Steam client
/// itself (nothing to do with the Web API `SteamAchievementWatcher` polls).
class SteamAccountEntry {
  /// The 17-digit SteamID64, e.g. "76561197960287930".
  final String steamId64;

  /// The display name Steam had cached for this account, or empty if the
  /// file didn't carry one.
  final String personaName;

  /// Whether this is the account the Steam client last signed in as --
  /// `loginusers.vdf`'s own `MostRecent` flag, `"1"`/`"0"`.
  final bool mostRecent;

  const SteamAccountEntry({
    required this.steamId64,
    required this.personaName,
    required this.mostRecent,
  });

  @override
  String toString() =>
      'SteamAccountEntry($steamId64, $personaName, mostRecent: $mostRecent)';
}

/// Parses the TEXT content of a `loginusers.vdf` file leniently: a regex
/// over 17-digit-quoted blocks, not a real VDF/KeyValues grammar -- Valve's
/// format is simple enough (and this reads no further than its own account
/// list) that a full parser would be YAGNI. Malformed content, or content
/// with no 17-digit account blocks at all, returns an empty list rather
/// than throwing -- callers treat "nothing detected" as the normal case
/// (no Steam installed, a fresh/never-logged-in client, a future format
/// change), not an error.
List<SteamAccountEntry> parseLoginUsersVdf(String contents) {
  final entries = <SteamAccountEntry>[];
  // Matches `"<17 digits>" { ... }`, non-greedy up to the first closing
  // brace -- loginusers.vdf never nests braces inside one account's block.
  final blockPattern = RegExp(r'"(\d{17})"\s*\{(.*?)\}', dotAll: true);
  final personaPattern = RegExp(r'"PersonaName"\s*"([^"]*)"');
  final mostRecentPattern = RegExp(r'"MostRecent"\s*"(\d+)"');
  for (final block in blockPattern.allMatches(contents)) {
    final body = block.group(2) ?? '';
    entries.add(SteamAccountEntry(
      steamId64: block.group(1)!,
      personaName: personaPattern.firstMatch(body)?.group(1) ?? '',
      mostRecent: mostRecentPattern.firstMatch(body)?.group(1) == '1',
    ));
  }
  return entries;
}

/// Picks the account onboarding/Settings should silently prefill, per the
/// friction-cut spec: the sole account, or -- among several -- whichever is
/// flagged [SteamAccountEntry.mostRecent] (exactly one, never more; Steam
/// itself only ever marks one account MostRecent at a time). Null when
/// there's no unambiguous pick, i.e. multiple accounts and none (or more
/// than one, a malformed file) flagged MostRecent -- the caller then falls
/// back to a manual choice instead of guessing.
SteamAccountEntry? pickMostLikelyAccount(List<SteamAccountEntry> entries) {
  if (entries.length == 1) return entries.first;
  final mostRecent = entries.where((e) => e.mostRecent).toList();
  return mostRecent.length == 1 ? mostRecent.first : null;
}

/// Reads Steam's local account cache and returns every account found --
/// always a list (possibly empty), never throwing: no Steam install, no
/// login history yet, or a permissions/IO error are all just "nothing to
/// detect", not failures worth surfacing.
///
/// Pure aside from the two injected callbacks, so tests can exercise the
/// per-platform path selection and picking logic hermetically:
///  - [readFile] abstracts the actual disk read -- return null for a path
///    that doesn't exist (never throw); production wires this to
///    `File(path).readAsString()` guarded by an `existsSync()` check.
///  - [listCrossOverBottleVdfPaths], macOS only, abstracts the CrossOver-
///    bottle glob (`~/Library/Application Support/CrossOver/Bottles/*/
///    drive_c/Program Files (x86)/Steam/config/loginusers.vdf`) so tests can
///    inject a fixed candidate list instead of scanning a real filesystem.
///    Defaults to no candidates (native Steam only) when omitted.
///
/// Every candidate path is tried in order (native install first, then any
/// CrossOver bottles); the first one that both exists and parses to at
/// least one account wins -- an empty/garbled file at an earlier candidate
/// falls through to the next rather than reporting no accounts at all.
Future<List<SteamAccountEntry>> locateSteamAccounts({
  required String homeDir,
  required bool isMacOS,
  required bool isWindows,
  required Future<String?> Function(String path) readFile,
  List<String> Function()? listCrossOverBottleVdfPaths,
}) async {
  final candidates = <String>[];
  if (isMacOS) {
    candidates.add(p.join(homeDir, 'Library', 'Application Support', 'Steam',
        'config', 'loginusers.vdf'));
    candidates.addAll(listCrossOverBottleVdfPaths?.call() ?? const []);
  } else if (isWindows) {
    candidates.add(r'C:\Program Files (x86)\Steam\config\loginusers.vdf');
  }
  for (final path in candidates) {
    final contents = await readFile(path);
    if (contents == null) continue;
    final entries = parseLoginUsersVdf(contents);
    if (entries.isNotEmpty) return entries;
  }
  return const [];
}

/// Real-filesystem glob for CrossOver bottles' `loginusers.vdf` -- the
/// production [locateSteamAccounts] `listCrossOverBottleVdfPaths` wiring
/// (see `steam_account_locator_prod.dart`... kept in this file since it's
/// the only production wiring this module needs). Lists every immediate
/// child of `~/Library/Application Support/CrossOver/Bottles/`, one
/// candidate path per bottle; a missing Bottles dir (no CrossOver
/// installed) just yields no candidates.
List<String> globCrossOverBottleVdfPaths(String homeDir) {
  final bottlesDir = Directory(p.join(
      homeDir, 'Library', 'Application Support', 'CrossOver', 'Bottles'));
  if (!bottlesDir.existsSync()) return const [];
  try {
    return bottlesDir
        .listSync()
        .whereType<Directory>()
        .map((bottle) => p.join(bottle.path, 'drive_c', 'Program Files (x86)',
            'Steam', 'config', 'loginusers.vdf'))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// Reads a file's contents for [locateSteamAccounts]' `readFile` wiring,
/// returning null (never throwing) when it doesn't exist or can't be read.
Future<String?> readFileOrNull(String path) async {
  final file = File(path);
  if (!await file.exists()) return null;
  try {
    return await file.readAsString();
  } catch (_) {
    return null;
  }
}

/// The real, this-machine wiring of [locateSteamAccounts] -- what
/// production code should call. Home directory comes from the platform
/// environment (`HOME` on macOS, `USERPROFILE` on Windows); an unset
/// variable just means no candidates match, same as "Steam not installed".
Future<List<SteamAccountEntry>> locateSteamAccountsOnThisMachine() {
  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ?? '')
      : (Platform.environment['HOME'] ?? '');
  return locateSteamAccounts(
    homeDir: home,
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
    readFile: readFileOrNull,
    listCrossOverBottleVdfPaths:
        Platform.isMacOS ? () => globCrossOverBottleVdfPaths(home) : null,
  );
}
