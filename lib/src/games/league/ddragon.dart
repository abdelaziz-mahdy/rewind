import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../log/log.dart';

/// Data Dragon — Riot's official, public, unauthenticated static-asset CDN
/// (champion/item art). Riot's Developer API Policy explicitly permits
/// "Game-Specific static data" as usable IP, which is what this is; see
/// docs/COMPLIANCE.md (and note Rewind must display Riot's legal boilerplate,
/// which it does in Settings → About).
///
/// Everything is cached to disk on first use and read from disk forever after,
/// so a match in progress never pays a network cost — the whole point, since
/// Rewind is running while you game.
class DDragon {
  DDragon({
    required this.cacheDir,
    Future<String?> Function(Uri url)? fetchText,
    Future<List<int>?> Function(Uri url)? fetchBytes,
  })  : _fetchText = fetchText ?? _defaultFetchText,
        _fetchBytes = fetchBytes ?? _defaultFetchBytes;

  /// Root for cached assets (a `.ddragon/` dir beside the clips).
  final Directory cacheDir;

  final Future<String?> Function(Uri url) _fetchText;
  final Future<List<int>?> Function(Uri url) _fetchBytes;

  static const _host = 'ddragon.leagueoflegends.com';

  String? _version;
  Future<String?>? _versionInFlight;

  /// The Data Dragon version to build asset URLs from (e.g. "16.14.1").
  ///
  /// Resolved once per session from Riot's versions.json (newest first) and
  /// then remembered — including across launches, via a small marker file, so
  /// a cold start with no network still resolves to the last known-good
  /// version rather than losing every asset.
  Future<String?> version() {
    if (_version != null) return Future.value(_version);
    return _versionInFlight ??= _resolveVersion();
  }

  Future<String?> _resolveVersion() async {
    final marker = File(p.join(cacheDir.path, 'version.txt'));
    final body = await _fetchText(Uri.https(_host, '/api/versions.json'));
    if (body != null) {
      try {
        final list = jsonDecode(body) as List<dynamic>;
        if (list.isNotEmpty) {
          _version = list.first as String;
          await marker.parent.create(recursive: true);
          await marker.writeAsString(_version!);
          return _version;
        }
      } catch (err) {
        talker.warning('Data Dragon versions.json unparseable: $err');
      }
    }
    // Offline (or Riot hiccuped): fall back to the last version we saw so
    // already-cached art keeps resolving instead of silently disappearing.
    if (await marker.exists()) {
      _version = (await marker.readAsString()).trim();
      if (_version!.isEmpty) _version = null;
    }
    return _version;
  }

  /// The Data Dragon champion key for a player's `rawChampionName`.
  ///
  /// The Live Client Data API reports BOTH `championName` (the display name,
  /// e.g. "Wukong") and `rawChampionName` (e.g.
  /// "game_character_displayname_MonkeyKing"). Data Dragon keys its art by the
  /// INTERNAL id ("MonkeyKing"), not the display name — so deriving the key
  /// from the raw name is what keeps Wukong, Nunu & Willump, Renata Glasc and
  /// friends from 404ing. Verified against a live match 2026-07-16
  /// ("game_character_displayname_Syndra" → "Syndra").
  ///
  /// Falls back to [championName] (stripped of spaces/punctuation) when the
  /// raw form is missing or unrecognised.
  static String? championKey(String? rawChampionName, {String? championName}) {
    final raw = rawChampionName?.trim();
    if (raw != null && raw.isNotEmpty) {
      final i = raw.lastIndexOf('_');
      final key = i >= 0 ? raw.substring(i + 1) : raw;
      if (key.isNotEmpty) return key;
    }
    final display = championName?.trim();
    if (display == null || display.isEmpty) return null;
    return display.replaceAll(RegExp(r"[^A-Za-z0-9]"), '');
  }

  /// Local file for a champion's square portrait, downloading + caching it on
  /// first use. Null when the key/version can't be resolved or the fetch
  /// fails — callers fall back to a monogram rather than showing a hole.
  Future<File?> championSquare(String? rawChampionName,
          {String? championName}) async =>
      _asset(
        subdir: 'champion',
        name: championKey(rawChampionName, championName: championName),
      );

  /// Local file for an item's icon by its `itemID` (as reported by the Live
  /// Client Data API's `items[].itemID`), downloading + caching on first use.
  Future<File?> itemIcon(int itemId) async =>
      _asset(subdir: 'item', name: '$itemId');

  Future<File?> _asset({required String subdir, required String? name}) async {
    if (name == null || name.isEmpty) return null;
    final v = await version();
    if (v == null) return null;

    final file = File(p.join(cacheDir.path, v, subdir, '$name.png'));
    if (await file.exists() && await file.length() > 0) return file;

    final bytes =
        await _fetchBytes(Uri.https(_host, '/cdn/$v/img/$subdir/$name.png'));
    if (bytes == null || bytes.isEmpty) return null;
    try {
      await file.parent.create(recursive: true);
      await file.writeAsBytes(bytes, flush: true);
      return file;
    } catch (err) {
      talker.warning('Data Dragon: could not cache $subdir/$name: $err');
      return null;
    }
  }

  static Future<String?> _defaultFetchText(Uri url) async {
    try {
      final client = HttpClient()..connectionTimeout = _timeout;
      final res = await client.getUrl(url).then((r) => r.close());
      if (res.statusCode != 200) return null;
      final body = await res.transform(utf8.decoder).join();
      client.close();
      return body;
    } catch (err) {
      talker.warning('Data Dragon fetch failed ($url): $err');
      return null;
    }
  }

  static Future<List<int>?> _defaultFetchBytes(Uri url) async {
    try {
      final client = HttpClient()..connectionTimeout = _timeout;
      final res = await client.getUrl(url).then((r) => r.close());
      if (res.statusCode != 200) return null;
      final bytes = <int>[];
      await for (final chunk in res) {
        bytes.addAll(chunk);
      }
      client.close();
      return bytes;
    } catch (err) {
      talker.warning('Data Dragon fetch failed ($url): $err');
      return null;
    }
  }

  static const _timeout = Duration(seconds: 10);
}
