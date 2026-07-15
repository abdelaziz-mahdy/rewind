import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

  @override
  String get gameId => 'league_of_legends';

  @override
  String get displayName => 'League of Legends';

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

      for (final e in events) {
        final map = (e as Map).cast<String, dynamic>();
        final id = (map['EventID'] as num?)?.toInt() ?? -1;
        if (id <= _lastEventId) continue;
        _lastEventId = id;

        final name = map['EventName'] as String? ?? '';
        final kind = _mapEvent(name);
        if (kind == null) continue;
        if (!_involvesActivePlayer(name, map)) continue;

        talker.info('League: ${kind.name} (event #$id, $name)');
        _controller
            .add(GameEvent(gameId: gameId, kind: kind, meta: {'raw': map}));
      }
    } catch (err, stack) {
      // Match likely ended mid-body or the payload changed shape; log once
      // per occurrence and keep polling.
      talker.handle(err, stack);
    } finally {
      _polling = false;
    }
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

  /// Whether [map]'s event involves the active player as the actor.
  /// Match-wide events (GameEnd) always pass; everything player-attributed
  /// requires the KillerName/Acer to be us — being someone else's victim is
  /// not a highlight.
  bool _involvesActivePlayer(String eventName, Map<String, dynamic> map) {
    if (eventName == 'GameEnd') return true;
    final actor =
        (eventName == 'Ace' ? map['Acer'] : map['KillerName']) as String?;
    return _isActivePlayer(actor);
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

  GameEventKind? _mapEvent(String name) {
    switch (name) {
      case 'ChampionKill':
        return GameEventKind.kill;
      case 'Multikill':
        return GameEventKind.doubleKill; // TODO: read KillStreak for exact tier
      case 'Ace':
        return GameEventKind.ace;
      case 'DragonKill':
        return GameEventKind.dragonKill;
      case 'BaronKill':
        return GameEventKind.baronKill;
      case 'TurretKilled':
        return GameEventKind.turretKill;
      case 'InhibKilled':
        return GameEventKind.inhibitorKill;
      case 'GameEnd':
        return GameEventKind.other;
      default:
        return null;
    }
  }
}
