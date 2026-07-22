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
    // p.posix.join, not the ambient p.join: this is a macOS path regardless
    // of the host running the locator (e.g. Windows CI), and the ambient
    // joiner would emit backslashes there — same reasoning as the Steam-root
    // resolver below.
    candidates.add(p.posix.join(homeDir, 'Library', 'Application Support',
        'Steam', 'config', 'loginusers.vdf'));
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

/// SteamID64's fixed offset from an account's 32-bit "id3" -- Valve's own
/// public numbering scheme (unrelated to any sanctioned-source concern:
/// this is pure arithmetic on an id the user's own `loginusers.vdf` already
/// hands us). [SteamStatsWatcher] needs id3 because that's the form Steam's
/// own client embeds in `UserGameStats_<id3>_<appid>.bin` filenames.
const steamId64ToId3Offset = 76561197960265728;

/// Converts a [SteamAccountEntry.steamId64] to its 32-bit "id3" form, or
/// null if [steamId64] isn't a plain 17-digit numeric id (e.g. still an
/// unresolved vanity name -- `loginusers.vdf` itself always stores the
/// numeric id64, so this should only fail on genuinely malformed input) or
/// resolves to a negative id3 (would indicate corrupt data; Steam never
/// issues one).
int? accountId3FromSteamId64(String steamId64) {
  final id = int.tryParse(steamId64);
  if (id == null) return null;
  final id3 = id - steamId64ToId3Offset;
  return id3 >= 0 ? id3 : null;
}

/// One local Steam CLIENT INSTALL ("tree") found on this machine -- native,
/// or a CrossOver bottle (each bottle is a fully independent client with its
/// own accounts/library, see `SteamStatsWatcher`'s doc). [rootPath] is the
/// Steam install directory itself (e.g. `.../Steam`, not `.../Steam/config`)
/// so callers can join it with `appcache/stats`, `config`, etc.
class SteamTree {
  final String rootPath;

  /// Every account id3 (see [accountId3FromSteamId64]) this tree's own
  /// `config/loginusers.vdf` lists -- multiple when more than one account
  /// has ever logged into this particular client install.
  final List<int> accountId3s;

  const SteamTree({required this.rootPath, required this.accountId3s});

  @override
  String toString() => 'SteamTree($rootPath, accounts: $accountId3s)';
}

/// Finds every local Steam install ("tree") on this machine and, for each,
/// the account id3s its own `loginusers.vdf` lists -- the discovery pass
/// [SteamStatsWatcher] needs to watch ALL independent Steam clients at once
/// (unlike [locateSteamAccounts]' "first candidate that matches wins",
/// single-account design, which existing Settings UI still uses for its
/// SteamID auto-detect).
///
/// A root with no `loginusers.vdf` (Steam installed but never logged in,
/// or not installed at all) or an empty/unparseable one contributes no
/// [SteamTree] -- there'd be no id3 to build a stats filename with anyway,
/// so it's indistinguishable from "nothing to watch here" either way.
///
/// Pure aside from the two injected callbacks, mirroring [locateSteamAccounts]:
///  - [readFile] abstracts the disk read of each candidate's
///    `config/loginusers.vdf`; return null for a path that doesn't exist.
///  - [listCrossOverBottleSteamRoots], macOS only, abstracts the CrossOver-
///    bottle glob -- returns Steam INSTALL roots (not vdf paths), since a
///    tree needs its root for `appcache/stats` too. Defaults to no
///    candidates (native Steam only) when omitted.
Future<List<SteamTree>> locateSteamTrees({
  required String homeDir,
  required bool isMacOS,
  required bool isWindows,
  required bool isLinux,
  required Future<String?> Function(String path) readFile,
  List<String> Function()? listCrossOverBottleSteamRoots,
}) async {
  // p.posix.join explicitly (not the ambient p.join, which resolves against
  // the HOST platform) -- these branches build a path for a specific TARGET
  // platform via [isMacOS]/[isWindows]/[isLinux], which in a test can differ
  // from whatever OS is actually running the test. Windows paths are built
  // with literal backslashes below for the same reason (mirrors
  // [locateSteamAccounts]' existing windows candidate, which is a hardcoded
  // literal for exactly this reason).
  final roots = <String>[];
  if (isMacOS) {
    roots.add(p.posix.join(homeDir, 'Library', 'Application Support', 'Steam'));
    roots.addAll(listCrossOverBottleSteamRoots?.call() ?? const []);
  } else if (isWindows) {
    roots.add(r'C:\Program Files (x86)\Steam');
  } else if (isLinux) {
    roots.add(p.posix.join(homeDir, '.steam', 'steam'));
    roots.add(p.posix.join(homeDir, '.local', 'share', 'Steam'));
  }

  final trees = <SteamTree>[];
  final seenRoots = <String>{};
  for (final root in roots) {
    if (!seenRoots.add(root)) continue; // dedupe identical literal paths
    final vdfPath = isWindows
        ? '$root\\config\\loginusers.vdf'
        : p.posix.join(root, 'config', 'loginusers.vdf');
    final contents = await readFile(vdfPath);
    if (contents == null) continue;
    final accounts = parseLoginUsersVdf(contents);
    if (accounts.isEmpty) continue;
    final id3s = [
      for (final account in accounts)
        if (accountId3FromSteamId64(account.steamId64) case final id3?) id3,
    ];
    if (id3s.isEmpty) continue;
    trees.add(SteamTree(rootPath: root, accountId3s: id3s));
  }
  return trees;
}

/// Real-filesystem glob for CrossOver bottles' Steam install roots -- same
/// enumeration as [globCrossOverBottleVdfPaths] but stopping one level
/// short of `config/loginusers.vdf`, since [SteamTree] needs the root
/// itself. Listed separately (rather than deriving one from the other)
/// because the two need different suffixes and there's no shared caller
/// that would benefit from factoring them together (YAGNI).
List<String> globCrossOverBottleSteamRoots(String homeDir) {
  final bottlesDir = Directory(p.join(
      homeDir, 'Library', 'Application Support', 'CrossOver', 'Bottles'));
  if (!bottlesDir.existsSync()) return const [];
  try {
    return bottlesDir
        .listSync()
        .whereType<Directory>()
        .map((bottle) =>
            p.join(bottle.path, 'drive_c', 'Program Files (x86)', 'Steam'))
        .toList();
  } catch (_) {
    return const [];
  }
}

/// The real, this-machine wiring of [locateSteamTrees] -- what
/// [SteamStatsWatcher] uses by default. Mirrors
/// [locateSteamAccountsOnThisMachine]'s home-directory resolution, plus
/// Linux (`~/.steam/steam` and the Flatpak/newer-client
/// `~/.local/share/Steam`, per the brief).
Future<List<SteamTree>> locateSteamTreesOnThisMachine() {
  final home = Platform.isWindows
      ? (Platform.environment['USERPROFILE'] ?? '')
      : (Platform.environment['HOME'] ?? '');
  return locateSteamTrees(
    homeDir: home,
    isMacOS: Platform.isMacOS,
    isWindows: Platform.isWindows,
    isLinux: Platform.isLinux,
    readFile: readFileOrNull,
    listCrossOverBottleSteamRoots:
        Platform.isMacOS ? () => globCrossOverBottleSteamRoots(home) : null,
  );
}
