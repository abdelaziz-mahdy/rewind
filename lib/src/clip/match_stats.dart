import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../events/game_event.dart';
import '../log/log.dart';

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

/// A single timestamped moment inside a match — the raw material for the
/// player's timeline markers (`lib/src/clip/clip_markers.dart`). Recorded for
/// every event `ClipCoordinator` already routes (kills, deaths, objectives,
/// aces, ...), not just the ones that trigger a clip save, so a clip's
/// markers reflect everything that happened during its footage window.
@immutable
class MatchEventStamp {
  final GameEventKind kind;
  final DateTime at;

  const MatchEventStamp({required this.kind, required this.at});

  Map<String, dynamic> toJson() =>
      {'kind': kind.name, 'at': at.toIso8601String()};

  /// Unknown/missing `kind` falls back to [GameEventKind.other] rather than
  /// throwing — same defensive shape as [Clip.fromJson]'s event parsing.
  factory MatchEventStamp.fromJson(Map<String, dynamic> j) => MatchEventStamp(
        kind: GameEventKind.values.firstWhere((k) => k.name == j['kind'],
            orElse: () => GameEventKind.other),
        at: DateTime.parse(j['at'] as String),
      );

  @override
  bool operator ==(Object other) =>
      other is MatchEventStamp && other.kind == kind && other.at == at;

  @override
  int get hashCode => Object.hash(kind, at);
}

/// The final outcome of a match, when the game reports one (League's
/// `GameEnd` event carries a `Result`). Null until/unless reported —
/// process-only games and matches from before this feature never have it.
enum MatchResult {
  win,
  loss;

  static MatchResult? tryParse(String? s) => switch (s?.toLowerCase()) {
        'win' => MatchResult.win,
        'loss' => MatchResult.loss,
        _ => null,
      };
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

  /// Every timestamped event recorded during this match (see
  /// [MatchEventStamp]), oldest first, capped at [MatchStatsStore.maxEvents]
  /// — a long match must not grow `matches.json` unboundedly. Empty for
  /// matches from before this feature (or any match with no combat).
  List<MatchEventStamp> events;

  /// The last moment anything about this match changed (an event landed, a
  /// stats snapshot differed, match info arrived). What
  /// [MatchStatsStore.latestFor] ranks by, and what the coordinator's
  /// restart-resume check compares against: a match whose stats were still
  /// moving seconds before app launch is a match the app was killed in the
  /// middle of. Defaults to [startedAt] (also for persisted matches from
  /// before this field existed — safely "long ago" by the time it matters).
  DateTime updatedAt;

  /// The match's final win/loss, when the game reported one at match end
  /// (see [MatchResult]). Null while the match is live, for process-only
  /// games, and for matches from before this feature.
  MatchResult? result;

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
    List<MatchEventStamp>? events,
    DateTime? updatedAt,
    this.result,
  })  : allies = allies ?? [],
        enemies = enemies ?? [],
        items = items ?? [],
        events = events ?? [],
        updatedAt = updatedAt ?? startedAt;

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
        'events': events.map((e) => e.toJson()).toList(),
        'updatedAt': updatedAt.toIso8601String(),
        'result': result?.name,
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
        events: ((j['events'] as List?) ?? const [])
            .map((e) =>
                MatchEventStamp.fromJson((e as Map).cast<String, dynamic>()))
            .toList(),
        updatedAt: DateTime.tryParse(j['updatedAt'] as String? ?? ''),
        result: MatchResult.tryParse(j['result'] as String?),
      );
}

/// Persistent store of per-match K/D, saved as `matches.json` beside the
/// clips. A [ChangeNotifier] so match cards rebuild live as kills/deaths
/// land during a game.
class MatchStatsStore extends ChangeNotifier {
  final Directory dir;
  final Map<String, MatchStats> _byKey = {};

  /// Cap on [MatchStats.events] per match (see [recordEvent]) — a long match
  /// must not grow `matches.json` unboundedly; oldest entries are dropped
  /// first since the timeline only needs each clip's own nearby window, not
  /// the full match history.
  static const int maxEvents = 500;

  /// Whether the [maxEvents] cap has already been logged once this session —
  /// a match that stays over the cap for its whole remaining runtime must
  /// not spam the log on every single subsequent event.
  bool _loggedEventCap = false;

  MatchStatsStore({required this.dir});

  static String _key(String gameId, DateTime startedAt) =>
      '$gameId|${startedAt.toIso8601String()}';

  File get _file => File(p.join(dir.path, 'matches.json'));

  /// The stats for a match, or null if none were recorded (e.g. a session
  /// with no combat, or clips from before this feature existed).
  MatchStats? statsFor(String gameId, DateTime startedAt) =>
      _byKey[_key(gameId, startedAt)];

  /// The most recently touched match for [gameId] (by [MatchStats.
  /// updatedAt]), or null if the game has none. Used by the coordinator's
  /// restart-resume check — see [MatchStats.updatedAt].
  MatchStats? latestFor(String gameId) {
    MatchStats? best;
    for (final m in _byKey.values) {
      if (m.gameId != gameId) continue;
      if (best == null || m.updatedAt.isAfter(best.updatedAt)) best = m;
    }
    return best;
  }

  MatchStats _ensure(String gameId, DateTime startedAt) => _byKey.putIfAbsent(
        _key(gameId, startedAt),
        () => MatchStats(gameId: gameId, startedAt: startedAt),
      );

  /// The ONE code path that records a match event: bumps [MatchStats.kills]/
  /// [MatchStats.deaths] for those two kinds, and appends an [MatchEventStamp]
  /// for every kind (so the player timeline has markers for objectives/aces/
  /// etc. too) — see that class's doc. [recordKill]/[recordDeath] are thin
  /// wrappers over this so there is exactly one place a kill/death is ever
  /// counted (no double-counting risk from two independent increment sites).
  void recordEvent(
      String gameId, DateTime startedAt, GameEventKind kind, DateTime at) {
    final m = _ensure(gameId, startedAt);
    m.updatedAt = at;
    if (kind == GameEventKind.kill) {
      m.kills++;
    } else if (kind == GameEventKind.death) {
      m.deaths++;
    }
    m.events.add(MatchEventStamp(kind: kind, at: at));
    if (m.events.length > maxEvents) {
      m.events.removeRange(0, m.events.length - maxEvents);
      if (!_loggedEventCap) {
        _loggedEventCap = true;
        talker.warning(
            'Match event log capped at $maxEvents; dropping oldest entries.');
      }
    }
    _persist();
  }

  void recordKill(String gameId, DateTime startedAt) =>
      recordEvent(gameId, startedAt, GameEventKind.kill, DateTime.now());

  void recordDeath(String gameId, DateTime startedAt) =>
      recordEvent(gameId, startedAt, GameEventKind.death, DateTime.now());

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
    m.updatedAt = DateTime.now();
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

  /// Records the match's final win/loss (from the game's match-end event —
  /// see `LeagueEventWatcher`'s GameEnd handling). Once set it's not
  /// overwritten: match end fires once, and a stray later report shouldn't
  /// flip a decided result.
  void recordOutcome(String gameId, DateTime startedAt, MatchResult result) {
    final m = _ensure(gameId, startedAt);
    if (m.result != null) return;
    m.result = result;
    m.updatedAt = DateTime.now();
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
    if (changed) {
      m.updatedAt = DateTime.now();
      _persist();
    }
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
