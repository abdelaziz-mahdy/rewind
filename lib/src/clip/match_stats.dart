import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// One item in a match's final build: `itemID`/`slot` are exactly the keys
/// the Live Client Data API's `playerlist[].items[]` uses (verified live
/// 2026-07-16) — kept minimal deliberately (no display name/price/etc.),
/// since `matches.json` is written often and every extra byte is written
/// again on every future update to this match. `DDragon.itemIcon(itemId)`
/// resolves the icon at render time; nothing about the art is persisted.
@immutable
class MatchItemSlot {
  final int itemId;
  final int slot;

  const MatchItemSlot({required this.itemId, required this.slot});

  Map<String, dynamic> toJson() => {'itemId': itemId, 'slot': slot};

  factory MatchItemSlot.fromJson(Map<String, dynamic> j) => MatchItemSlot(
        itemId: (j['itemId'] as num?)?.toInt() ?? 0,
        slot: (j['slot'] as num?)?.toInt() ?? 0,
      );

  @override
  bool operator ==(Object other) =>
      other is MatchItemSlot && other.itemId == itemId && other.slot == slot;

  @override
  int get hashCode => Object.hash(itemId, slot);
}

/// One other player in the match, as shown in `MatchClipsScreen`'s
/// YOUR TEAM / ENEMIES lists: their champion AND their name together, so the
/// two can never drift out of sync the way a second parallel `List<String>`
/// of names could. This is local-only data the player already sees on their
/// own in-game scoreboard — Rewind never uploads or shares it (see
/// docs/COMPLIANCE.md).
@immutable
class MatchPlayer {
  final String championName;

  /// The RAW champion form (e.g. "game_character_displayname_MonkeyKing"),
  /// for art — same convention as [MatchStats.championKey]. Null when the
  /// source payload didn't carry it (older polls, or a shape Riot changes).
  final String? championKey;

  /// "Name#TAG" (preferring `riotId`, since Riot has deprecated summoner
  /// names — see `LeagueEventWatcher._riotIdOf`), or null when unresolvable.
  final String? riotId;

  const MatchPlayer(
      {required this.championName, this.championKey, this.riotId});

  Map<String, dynamic> toJson() => {
        'championName': championName,
        'championKey': championKey,
        'riotId': riotId
      };

  /// Accepts the current object shape AND a legacy bare champion-name
  /// string — `matches.json` files written before usernames were tracked
  /// stored `allies`/`enemies` as plain `List<String>`, and there IS a real
  /// one of those on disk that must keep loading, not crash.
  factory MatchPlayer.fromDynamic(dynamic j) {
    if (j is String) return MatchPlayer(championName: j);
    final m = (j as Map).cast<String, dynamic>();
    return MatchPlayer(
      championName: m['championName'] as String? ?? '',
      championKey: m['championKey'] as String?,
      riotId: m['riotId'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is MatchPlayer &&
      other.championName == championName &&
      other.championKey == championKey &&
      other.riotId == riotId;

  @override
  int get hashCode => Object.hash(championName, championKey, riotId);

  @override
  String toString() => 'MatchPlayer($championName, riotId: $riotId)';
}

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
  List<MatchPlayer> allies; // teammates (champion + name, excludes the player)
  List<MatchPlayer> enemies; // opponents (champion + name)

  /// The player's `rawChampionName` (e.g.
  /// "game_character_displayname_MonkeyKing") — the RAW form
  /// `DDragon.championSquare` expects, kept as-is rather than pre-parsed so
  /// all the internal-id derivation stays in one place (`DDragon.
  /// championKey`). Captured once alongside [champion]/[gameMode] in
  /// `_recordMatchInfo` — stable for the whole match (champion select is
  /// over by the time the client data API is up).
  String? championKey;

  /// The player's skin, e.g. "Pentakill III: Lost Chapter Kayle". Captured
  /// once, same as [championKey].
  String? skinName;

  /// Live combat-support stats only available via `playerlist[].scores`
  /// (kills/deaths themselves are already tracked via [recordKill]/
  /// [recordDeath] from combat events). Updated on every poll while the
  /// match is live — see [MatchStatsStore.recordStatsUpdate].
  int assists;
  int creepScore;
  double wardScore;

  /// The final (most-recently-seen) item build, ordered by [MatchItemSlot.
  /// slot] by convention at render time (not enforced here — this is
  /// whatever `playerlist[].items` reported).
  List<MatchItemSlot> items;

  MatchStats({
    required this.gameId,
    required this.startedAt,
    this.kills = 0,
    this.deaths = 0,
    this.gameMode,
    this.champion,
    List<MatchPlayer>? allies,
    List<MatchPlayer>? enemies,
    this.championKey,
    this.skinName,
    this.assists = 0,
    this.creepScore = 0,
    this.wardScore = 0.0,
    List<MatchItemSlot>? items,
  })  : allies = allies ?? [],
        enemies = enemies ?? [],
        items = items ?? [];

  Map<String, dynamic> toJson() => {
        'gameId': gameId,
        'startedAt': startedAt.toIso8601String(),
        'kills': kills,
        'deaths': deaths,
        'gameMode': gameMode,
        'champion': champion,
        'allies': allies.map((a) => a.toJson()).toList(),
        'enemies': enemies.map((e) => e.toJson()).toList(),
        'championKey': championKey,
        'skinName': skinName,
        'assists': assists,
        'creepScore': creepScore,
        'wardScore': wardScore,
        'items': items.map((i) => i.toJson()).toList(),
      };

  /// Backward-compatible with `matches.json` files written before this
  /// feature: every new field is optional and defaults sanely on a missing
  /// key rather than throwing (there IS a real matches.json on disk that
  /// predates all of them).
  factory MatchStats.fromJson(Map<String, dynamic> j) => MatchStats(
        gameId: j['gameId'] as String,
        startedAt: DateTime.parse(j['startedAt'] as String),
        kills: j['kills'] as int? ?? 0,
        deaths: j['deaths'] as int? ?? 0,
        gameMode: j['gameMode'] as String?,
        champion: j['champion'] as String?,
        allies: ((j['allies'] as List?) ?? const [])
            .map(MatchPlayer.fromDynamic)
            .toList(),
        enemies: ((j['enemies'] as List?) ?? const [])
            .map(MatchPlayer.fromDynamic)
            .toList(),
        championKey: j['championKey'] as String?,
        skinName: j['skinName'] as String?,
        assists: j['assists'] as int? ?? 0,
        creepScore: j['creepScore'] as int? ?? 0,
        wardScore: (j['wardScore'] as num?)?.toDouble() ?? 0.0,
        items: ((j['items'] as List?) ?? const [])
            .map((e) =>
                MatchItemSlot.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
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
    List<MatchPlayer>? allies,
    List<MatchPlayer>? enemies,
    String? rawChampionName,
    String? skinName,
  }) {
    final m = _ensure(gameId, startedAt);
    if (gameMode != null && gameMode.isNotEmpty) m.gameMode = gameMode;
    if (champion != null && champion.isNotEmpty) m.champion = champion;
    if (allies != null && allies.isNotEmpty) m.allies = allies;
    if (enemies != null && enemies.isNotEmpty) m.enemies = enemies;
    if (rawChampionName != null && rawChampionName.isNotEmpty) {
      m.championKey = rawChampionName;
    }
    if (skinName != null && skinName.isNotEmpty) m.skinName = skinName;
    _persist();
  }

  /// Records a live stats snapshot (assists/creepScore/wardScore/items) —
  /// see [GameEventKind.statsUpdate]'s doc for why this is separate from
  /// [recordMatchInfo]. Fired on every poll by the watcher, so this only
  /// actually persists when something changed — a match sitting idle
  /// between fights must not rewrite `matches.json` every 500 ms.
  void recordStatsUpdate(
    String gameId,
    DateTime startedAt, {
    int? assists,
    int? creepScore,
    double? wardScore,
    List<MatchItemSlot>? items,
  }) {
    final m = _ensure(gameId, startedAt);
    var changed = false;
    if (assists != null && assists != m.assists) {
      m.assists = assists;
      changed = true;
    }
    if (creepScore != null && creepScore != m.creepScore) {
      m.creepScore = creepScore;
      changed = true;
    }
    if (wardScore != null && wardScore != m.wardScore) {
      m.wardScore = wardScore;
      changed = true;
    }
    if (items != null && !listEquals(items, m.items)) {
      m.items = items;
      changed = true;
    }
    if (changed) _persist();
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
