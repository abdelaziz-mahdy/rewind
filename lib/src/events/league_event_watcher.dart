import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../games/league/game_modes.dart';
import '../log/log.dart';
import 'game_event.dart';
import 'game_event_source.dart';

/// Watches League of Legends via the local Live Client Data API.
///
/// While a match is running, the League client serves data on
/// https://127.0.0.1:2999 (localhost only). We poll
/// `/liveclientdata/eventdata` and translate new events into [GameEvent]s.
///
/// Two hard-won rules, both from a live Arena match (2026-07-14) that
/// produced a 44 MB clip every 5 seconds until the disk hit 99%:
///
///  1. **Events are match-global.** `eventdata` reports EVERY player's
///     kills — 16 players' worth in Arena — so each event must be checked
///     against `/liveclientdata/activeplayername` before it clips anything.
///  2. **History replays on connect.** The endpoint returns every event
///     since the match started; connecting mid-match (or restarting
///     Rewind) must seed past the backlog, not emit it.
class LeagueEventWatcher implements GameEventSource {
  static const _host = '127.0.0.1';
  static const _port = 2999;
  static const _pollInterval = Duration(milliseconds: 500);
  static const _requestTimeout = Duration(milliseconds: 600);

  /// Riot serves the API over TLS with a SELF-SIGNED certificate (their own
  /// root, not in the system trust store), so a stock HTTP client rejects
  /// the handshake — which left this watcher permanently blind: it reported
  /// "waiting for a match" straight through a live game (`curl -k` answered
  /// with live gamestats while every Dart request died in the handshake).
  /// Trust is scoped to EXACTLY 127.0.0.1:2999 — never a blanket pass.
  static final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 800)
    ..badCertificateCallback =
        ((cert, host, port) => host == _host && port == _port);

  /// GETs a Live Client Data path, returning the response body on HTTP 200
  /// and null on ANY failure — connection refused (no match: normal),
  /// timeouts, non-200s. Never throws.
  static Future<String?> _httpFetch(String path) async {
    try {
      final req = await _client
          .getUrl(Uri.https('$_host:$_port', path))
          .timeout(_requestTimeout);
      final res = await req.close().timeout(_requestTimeout);
      if (res.statusCode != 200) {
        await res.drain<void>();
        return null;
      }
      return await utf8.decoder.bind(res).join().timeout(_requestTimeout);
    } catch (_) {
      return null;
    }
  }

  /// The transport, injectable so tests can drive the watcher with canned
  /// API bodies instead of a real TLS server.
  final Future<String?> Function(String path) _fetch;

  LeagueEventWatcher({Future<String?> Function(String path)? fetch})
      : _fetch = fetch ?? _httpFetch;

  final _controller = StreamController<GameEvent>.broadcast();
  Timer? _timer;
  int _lastEventId = -1;

  /// Whether [_lastEventId] has been seeded from the first successful poll
  /// of this session (rule 2 above): everything already in the log at that
  /// point is history, not new activity.
  bool _seeded = false;

  /// The active player's riot id ("Name#TAG"), fetched once per session —
  /// the filter that keeps 15 other players' kills from clipping (rule 1).
  String? _activeName;

  /// Prevents overlapping polls: at a 500 ms interval with a 600 ms request
  /// timeout, two in-flight polls can read the same [_lastEventId] and
  /// double-emit every event.
  bool _polling = false;

  /// Whether the one-shot [GameEventKind.matchInfo] event (champion, teams,
  /// mode) has been emitted for this match. Reset per session in [stop].
  bool _infoSent = false;

  @override
  String get gameId => 'league_of_legends';

  @override
  String get displayName => 'League of Legends';

  /// Match-live IS this watcher's activation (see the class doc: it only
  /// activates while the Live Client Data API is up), so it always counts
  /// as playing — unlike the League client's generic catalog process entry
  /// (`app:league_of_legends`, see `game_catalog.dart`), which fires on the
  /// client alone.
  @override
  bool get countsAsPlaying => true;

  /// League is TWO separate macOS apps. The CLIENT the user browses
  /// lobby/champ-select/post-game in is `…/LoL/League of Legends.app`
  /// (bundle `com.riotgames.LeagueofLegends.LeagueClientUx`, display name
  /// "League of Legends") — the app the catalog's process-watch entry
  /// detects (`ProcessWatcherSource`, processMatch `LeagueClientUx`). The
  /// actual match runs in a SEPARATE app, `…/LoL/Game/LeagueofLegends.app`
  /// (bundle `com.riotgames.LeagueofLegends.GameClient`, CFBundleName
  /// `LeagueofLegends`), which only exists while a game is live. The client
  /// HIDES itself once a match starts, so binding capture to it for the
  /// whole match records a black canvas with just the cursor composited on
  /// top (verified live, 2026-07-18: a 28.7 s clip of exactly that).
  ///
  /// This watcher's activation IS match-live (see the class doc), so it
  /// re-aims capture at "GameClient" — deliberately NOT "LeagueClientUx" —
  /// which matches only the actual game app and never wrong-falls-back to
  /// the (by then hidden) client.
  @override
  String get processMatch => 'GameClient';

  @override
  Future<bool> isGameRunning() async =>
      await _fetch('/liveclientdata/gamestats') != null;

  @override
  Stream<GameEvent> events() => _controller.stream;

  @override
  Future<void> start() async {
    _timer ??= Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  Future<void> stop() async {
    _timer?.cancel();
    _timer = null;
    _lastEventId = -1;
    _seeded = false;
    _activeName = null;
    _infoSent = false;
  }

  /// Visible for tests: one poll cycle, exactly what the periodic timer
  /// runs.
  Future<void> pollNow() => _poll();

  Future<void> _poll() async {
    if (_polling) return;
    _polling = true;
    try {
      final body = await _fetch('/liveclientdata/eventdata');
      if (body == null) return;

      final data = jsonDecode(body) as Map<String, dynamic>;
      final events = (data['Events'] as List?) ?? const [];

      if (!_seeded) {
        // First successful poll of this session: everything already in the
        // log happened before we were watching. Seed past it.
        for (final e in events) {
          final id = ((e as Map)['EventID'] as num?)?.toInt() ?? -1;
          if (id > _lastEventId) _lastEventId = id;
        }
        _seeded = true;
        return;
      }

      // Lazily resolve who "we" are — required before any player-scoped
      // event may emit. Fail closed: no name, no clips (never spam).
      _activeName ??= await _fetchActiveName();

      // Player-scoped state off the SAME playerlist fetch: the one-shot
      // match metadata (champion, teams, mode) plus a fresh live-stats
      // snapshot every poll (assists/creepScore/wardScore/items).
      await _pollPlayerState();

      for (final e in events) {
        final map = (e as Map).cast<String, dynamic>();
        final id = (map['EventID'] as num?)?.toInt() ?? -1;
        if (id <= _lastEventId) continue;
        _lastEventId = id;

        final name = map['EventName'] as String? ?? '';
        // One raw event can yield more than one GameEvent: a ChampionKill
        // where the active player is BOTH killer and victim can't happen,
        // but keeping this a list means deaths and kills share one code
        // path and future many-to-one mappings stay simple.
        for (final kind in _kindsFor(name, map)) {
          talker.info('League: ${kind.name} (event #$id, $name)');
          _controller
              .add(GameEvent(gameId: gameId, kind: kind, meta: {'raw': map}));
        }
      }
    } catch (err, stack) {
      // Match likely ended mid-body or the payload changed shape; log once
      // per occurrence and keep polling.
      talker.handle(err, stack);
    } finally {
      _polling = false;
    }
  }

  /// Fetches `/liveclientdata/playerlist` once per poll and, off the active
  /// player's row: (a) emits the one-shot [GameEventKind.matchInfo] the
  /// first time it resolves (champion, teams, mode, skin — stable for the
  /// whole match, see [_emitMatchInfo]), and (b) emits a fresh
  /// [GameEventKind.statsUpdate] every poll (assists/creepScore/wardScore/
  /// items — these DO change over the match, see [_emitStatsUpdate]).
  /// No-ops (retries next poll) when the endpoint or the active player's row
  /// isn't resolvable yet.
  Future<void> _pollPlayerState() async {
    final listBody = await _fetch('/liveclientdata/playerlist');
    if (listBody == null) return;

    List<Map<String, dynamic>> players;
    try {
      players = (jsonDecode(listBody) as List)
          .map((e) => (e as Map).cast<String, dynamic>())
          .toList();
    } catch (err, stack) {
      talker.handle(err, stack);
      return;
    }

    // Find "me": match by riotId (preferred) or the tagless summoner name.
    Map<String, dynamic>? me;
    for (final p in players) {
      final riotId = p['riotId'] as String?;
      final summoner = p['summonerName'] as String?;
      if (_isActivePlayer(riotId) || _isActivePlayer(summoner)) {
        me = p;
        break;
      }
    }
    if (me == null) return;

    if (!_infoSent) await _emitMatchInfo(players, me);
    _emitStatsUpdate(me);
  }

  /// Emits a one-shot [GameEventKind.matchInfo] with the active player's
  /// champion (+ its raw form/skin, for art), their teammates' and
  /// enemies' champions, and a friendly game-mode name. [players]/[me] come
  /// from [_pollPlayerState]'s single playerlist fetch; only `gamestats` (for
  /// the mode) is fetched separately here. Best-effort: a failure just
  /// retries next poll, since [_infoSent] stays false.
  Future<void> _emitMatchInfo(
      List<Map<String, dynamic>> players, Map<String, dynamic> me) async {
    String? rawMode;
    final statsBody = await _fetch('/liveclientdata/gamestats');
    if (statsBody != null) {
      try {
        final stats = jsonDecode(statsBody) as Map<String, dynamic>;
        rawMode = stats['gameMode'] as String?;
      } catch (_) {}
    }
    try {
      final myChampion = me['championName'] as String?;
      final myTeam = me['team'];

      // The ORDER/CHAOS `team` field is only a real 2-team split for
      // standard modes. In Arena (CHERRY) it buckets everyone into two
      // arbitrary, unbalanced halves (verified live: 12 ORDER / 6 CHAOS in
      // an 18-player game) — NOT the actual duos, which the API doesn't
      // expose. So for anything that isn't a clean 2-team mode, we don't
      // fake a "your team": every other champion goes into a single flat
      // list (carried in `enemies`, with `allies` empty — the UI renders
      // that as a neutral "champions in this game").
      final twoTeam = isTwoTeamLeagueMode(rawMode) && myTeam != null;
      final allies = <Map<String, dynamic>>[];
      final enemies = <Map<String, dynamic>>[];
      for (final p in players) {
        if (identical(p, me)) continue;
        final champ = p['championName'] as String?;
        if (champ == null || champ.isEmpty) continue;
        // Champion AND name together in one entry (never two parallel
        // lists that could drift out of sync) — the keys match
        // `MatchPlayer.fromDynamic`'s shape exactly, so the coordinator can
        // parse each straight through with no remapping.
        final player = {
          'championName': champ,
          'championKey': p['rawChampionName'] as String?,
          'riotId': _riotIdOf(p),
        };
        if (twoTeam && p['team'] == myTeam) {
          allies.add(player);
        } else {
          enemies.add(player);
        }
      }

      talker.info('League match: champion=$myChampion mode=$rawMode '
          'twoTeam=$twoTeam allies=${allies.length} others=${enemies.length}');
      _controller
          .add(GameEvent(gameId: gameId, kind: GameEventKind.matchInfo, meta: {
        // The RAW code ("KIWI"), not a friendly name: the display name is
        // derived at render by friendlyLeagueGameMode(). Persisting the
        // derived name froze it — every match recorded before ARAM Mayhem was
        // mapped is stuck reading "Kiwi" forever. See games/league/game_modes.dart.
        'gameMode': rawMode,
        'champion': myChampion,
        'allies': allies,
        'enemies': enemies,
        // Stable for the whole match (champion select is long over by the
        // time the Live Client Data API is up) — captured once here rather
        // than every poll like [_emitStatsUpdate]'s fields.
        'rawChampionName': me['rawChampionName'] as String?,
        'skinName': me['skinName'] as String?,
      }));
      _infoSent = true;
    } catch (err, stack) {
      talker.handle(err, stack);
    }
  }

  /// Emits a fresh [GameEventKind.statsUpdate] off the active player's
  /// CURRENT `playerlist` row: `assists`/`creepScore`/`wardScore` (only
  /// available via `scores` — kills/deaths themselves are already tracked
  /// via combat events, see [_kindsFor]) and the running `items` build —
  /// all of which change throughout the match, unlike [_emitMatchInfo]'s
  /// one-shot metadata. Fired every poll; [ClipCoordinator]/
  /// [MatchStatsStore] are responsible for not persisting when nothing
  /// actually changed.
  void _emitStatsUpdate(Map<String, dynamic> me) {
    final scores = (me['scores'] as Map?)?.cast<String, dynamic>();
    final items = ((me['items'] as List?) ?? const [])
        .map((e) => (e as Map).cast<String, dynamic>())
        .map((e) => {
              'itemId': (e['itemID'] as num?)?.toInt() ?? 0,
              'slot': (e['slot'] as num?)?.toInt() ?? 0,
            })
        .toList();

    _controller.add(GameEvent(
      gameId: gameId,
      kind: GameEventKind.statsUpdate,
      meta: {
        'assists': (scores?['assists'] as num?)?.toInt(),
        'creepScore': (scores?['creepScore'] as num?)?.toInt(),
        'wardScore': (scores?['wardScore'] as num?)?.toDouble(),
        'items': items,
      },
    ));
  }

  /// The best available "Name#TAG" for a `playerlist` row: `riotId` when
  /// present (Riot has deprecated summoner names — current docs describe
  /// `summonerName` as a compatibility shim over the RiotID), else
  /// `riotIdGameName`+`riotIdTagLine` combined, else the legacy
  /// `summonerName`. Null when none of those resolve.
  static String? _riotIdOf(Map<String, dynamic> p) {
    final riotId = p['riotId'] as String?;
    if (riotId != null && riotId.isNotEmpty) return riotId;
    final gameName = p['riotIdGameName'] as String?;
    final tagLine = p['riotIdTagLine'] as String?;
    if (gameName != null &&
        gameName.isNotEmpty &&
        tagLine != null &&
        tagLine.isNotEmpty) {
      return '$gameName#$tagLine';
    }
    final summoner = p['summonerName'] as String?;
    return (summoner != null && summoner.isNotEmpty) ? summoner : null;
  }

  Future<String?> _fetchActiveName() async {
    final body = await _fetch('/liveclientdata/activeplayername');
    if (body == null) return null;
    try {
      // The endpoint returns a bare JSON string: "Name#TAG".
      final name = jsonDecode(body);
      return name is String && name.isNotEmpty ? name : null;
    } catch (_) {
      return null;
    }
  }

  /// The [GameEventKind]s to emit for a raw event, scoped to the active
  /// player. `eventdata` is match-global (all players), so every
  /// player-attributed mapping checks the actor is us — being someone
  /// else's victim is not a highlight, but being the VICTIM ourselves is a
  /// death (counted for match K/D, never clipped).
  List<GameEventKind> _kindsFor(String name, Map<String, dynamic> map) {
    switch (name) {
      case 'ChampionKill':
        return [
          if (_isActivePlayer(map['KillerName'] as String?)) GameEventKind.kill,
          if (_isActivePlayer(map['VictimName'] as String?))
            GameEventKind.death,
        ];
      case 'Multikill':
        if (!_isActivePlayer(map['KillerName'] as String?)) return const [];
        // The Multikill event carries the streak tier in `KillStreak`
        // (2=double … 5=penta), and League fires a fresh Multikill event at
        // EACH tier as the streak grows — so mapping the value to its exact
        // kind is what distinguishes a penta from a double. An unknown/
        // missing value falls back to the lowest multikill rather than
        // dropping the highlight entirely.
        return switch ((map['KillStreak'] as num?)?.toInt()) {
          5 => const [GameEventKind.pentaKill],
          4 => const [GameEventKind.quadraKill],
          3 => const [GameEventKind.tripleKill],
          _ => const [GameEventKind.doubleKill],
        };
      case 'Ace':
        return _isActivePlayer(map['Acer'] as String?)
            ? const [GameEventKind.ace]
            : const [];
      case 'DragonKill':
        return _isActivePlayer(map['KillerName'] as String?)
            ? const [GameEventKind.dragonKill]
            : const [];
      case 'BaronKill':
        return _isActivePlayer(map['KillerName'] as String?)
            ? const [GameEventKind.baronKill]
            : const [];
      case 'TurretKilled':
        return _isActivePlayer(map['KillerName'] as String?)
            ? const [GameEventKind.turretKill]
            : const [];
      case 'InhibKilled':
        return _isActivePlayer(map['KillerName'] as String?)
            ? const [GameEventKind.inhibitorKill]
            : const [];
      case 'GameEnd':
        // The match-end event carries the active player's result in
        // `Result` ("Win"/"Lose"). Map it to victory/defeat so the
        // coordinator can record the match outcome (never a clip — see
        // ClipCoordinator's outcome handling); an absent/unknown result
        // stays a neutral `other` (older clients, spectator, remake).
        return switch ((map['Result'] as String?)?.toLowerCase()) {
          'win' => const [GameEventKind.victory],
          'lose' || 'loss' => const [GameEventKind.defeat],
          _ => const [GameEventKind.other],
        };
      default:
        return const [];
    }
  }

  /// True when [actor] names the active player. `activeplayername` returns
  /// the full riot id ("zezo12321#EUW") but events name players by GAME
  /// NAME with no tag ("Tjl77") — verified live 2026-07-14, where the
  /// mismatch made the fail-closed filter reject the player's OWN kills.
  /// Accept both forms; a future patch flipping event names to riot ids
  /// must not re-break this.
  bool _isActivePlayer(String? actor) {
    final me = _activeName;
    if (me == null || actor == null || actor.isEmpty) {
      return false; // fail closed (see _poll)
    }
    if (actor == me) return true;
    final hash = me.indexOf('#');
    return hash > 0 && actor == me.substring(0, hash);
  }
}
