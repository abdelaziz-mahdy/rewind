import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Kills and deaths the player accumulated in one match (play session),
/// keyed by the session's start time — the same [Clip.sessionAt] stamp the
/// coordinator writes onto that match's clips, so a match card can look up
/// its own K/D. Persisted independently of clips: a match's K/D reflects
/// what HAPPENED, not just the fights that got clipped.
class MatchStats {
  final String gameId;
  final DateTime startedAt;
  int kills;
  int deaths;

  /// League match metadata, captured once from the Live Client API when the
  /// match is first seen (see `LeagueEventWatcher`). All null/empty for
  /// games without a vendor API.
  String? gameMode; // friendly, e.g. "Arena", "ARAM", "Summoner's Rift"
  String? champion; // the champion the player is on
  List<String> allies; // teammates' champions (excludes the player)
  List<String> enemies; // opponents' champions

  MatchStats({
    required this.gameId,
    required this.startedAt,
    this.kills = 0,
    this.deaths = 0,
    this.gameMode,
    this.champion,
    List<String>? allies,
    List<String>? enemies,
  })  : allies = allies ?? [],
        enemies = enemies ?? [];

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'startedAt': startedAt.toIso8601String(),
        'kills': kills,
        'deaths': deaths,
        'gameMode': gameMode,
        'champion': champion,
        'allies': allies,
        'enemies': enemies,
      };

  factory MatchStats.fromJson(Map<String, dynamic> j) => MatchStats(
        gameId: j['gameId'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        kills: j['kills'] as int? ?? 0,
        deaths: j['deaths'] as int? ?? 0,
        gameMode: j['gameMode'] as String?,
        champion: j['champion'] as String?,
        allies: (j['allies'] as List?)?.cast<String>() ?? [],
        enemies: (j['enemies'] as List?)?.cast<String>() ?? [],
      );
}

/// Persistent store of per-match K/D, saved as `matches.json` beside the
/// clips. A [ChangeNotifier] so match cards rebuild live as kills/deaths
/// land during a game.
class MatchStatsStore extends ChangeNotifier {
  final Directory dir;
  final Map<String, MatchStats> _byKey = {};

  MatchStatsStore({required this.dir});

  static String _key(String gameId, DateTime startedAt) =>
      '$gameId|${startedAt.toIso8601String()}';

  File get _file => File(p.join(dir.path, 'matches.json'));

  /// The stats for a match, or null if none were recorded (e.g. a session
  /// with no combat, or clips from before this feature existed).
  MatchStats? statsFor(String gameId, DateTime startedAt) =>
      _byKey[_key(gameId, startedAt)];

  MatchStats _ensure(String gameId, DateTime startedAt) => _byKey.putIfAbsent(
        _key(gameId, startedAt),
        () => MatchStats(gameId: gameId, startedAt: startedAt),
      );

  void recordKill(String gameId, DateTime startedAt) {
    _ensure(gameId, startedAt).kills++;
    _persist();
  }

  void recordDeath(String gameId, DateTime startedAt) {
    _ensure(gameId, startedAt).deaths++;
    _persist();
  }

  /// Records the League match metadata (captured once per match). Only
  /// overwrites fields that are provided and non-empty, so a later poll
  /// can't blank out an earlier capture.
  void recordMatchInfo(
    String gameId,
    DateTime startedAt, {
    String? gameMode,
    String? champion,
    List<String>? allies,
    List<String>? enemies,
  }) {
    final m = _ensure(gameId, startedAt);
    if (gameMode != null && gameMode.isNotEmpty) m.gameMode = gameMode;
    if (champion != null && champion.isNotEmpty) m.champion = champion;
    if (allies != null && allies.isNotEmpty) m.allies = allies;
    if (enemies != null && enemies.isNotEmpty) m.enemies = enemies;
    _persist();
  }

  void _persist() {
    notifyListeners();
    // Fire-and-forget: a lost K/D increment is never worth blocking the
    // event loop or crashing.
    unawaited(save());
  }

  Future<void> save() async {
    try {
      await dir.create(recursive: true);
      final tmp = File('${_file.path}.tmp');
      await tmp.writeAsString(const JsonEncoder.withIndent('  ')
          .convert({'matches': _byKey.values.map((m) => m.toJson()).toList()}));
      await tmp.rename(_file.path);
    } catch (_) {
      // Best-effort persistence.
    }
  }

  static Future<MatchStatsStore> load(Directory dir) async {
    final store = MatchStatsStore(dir: dir);
    final file = store._file;
    if (await file.exists()) {
      try {
        final j = jsonDecode(await file.readAsString()) as Map;
        for (final e in (j['matches'] as List? ?? const [])) {
          final m = MatchStats.fromJson((e as Map).cast<String, dynamic>());
          store._byKey[_key(m.gameId, m.startedAt)] = m;
        }
      } catch (_) {
        // Corrupt file: start fresh (K/D is derivable-ish and non-critical).
        try {
          await file.rename('${file.path}.bad');
        } catch (_) {}
      }
    }
    return store;
  }
}
