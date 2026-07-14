import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'game_event.dart';
import 'game_event_source.dart';

/// Watches League of Legends via the local Live Client Data API.
///
/// While a match is running, the League client serves data on
/// https://127.0.0.1:2999 (localhost only). We poll
/// `/liveclientdata/eventdata` and translate new events into [GameEvent]s.
///
/// TODO(v0.2): de-duplicate events by EventID across reconnects, and map
/// multikills to their exact tier via KillStreak.
class LeagueEventWatcher implements GameEventSource {
  static const _host = '127.0.0.1';
  static const _port = 2999;
  static const _pollInterval = Duration(milliseconds: 500);
  static const _requestTimeout = Duration(milliseconds: 600);

  /// Riot serves the API over TLS with a SELF-SIGNED certificate (their own
  /// root, not in the system trust store), so a stock HTTP client rejects
  /// the handshake — which left this watcher permanently blind: it reported
  /// "waiting for a match" straight through a live game (observed
  /// 2026-07-14: `curl -k` answered with live gamestats while every Dart
  /// request died in the handshake). Trust is scoped to EXACTLY
  /// 127.0.0.1:2999 — never a blanket bad-certificate pass.
  final HttpClient _client = HttpClient()
    ..connectionTimeout = const Duration(milliseconds: 800)
    ..badCertificateCallback =
        ((cert, host, port) => host == _host && port == _port);

  final _controller = StreamController<GameEvent>.broadcast();
  Timer? _timer;
  int _lastEventId = -1;

  @override
  String get gameId => 'league_of_legends';

  @override
  String get displayName => 'League of Legends';

  /// GETs a Live Client Data path, returning the response body on HTTP 200
  /// and null on ANY failure — connection refused (no match: normal),
  /// timeouts, non-200s. Never throws.
  Future<String?> _get(String path) async {
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

  @override
  Future<bool> isGameRunning() async =>
      await _get('/liveclientdata/gamestats') != null;

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
  }

  Future<void> _poll() async {
    try {
      final body = await _get('/liveclientdata/eventdata');
      if (body == null) return;

      final data = jsonDecode(body) as Map<String, dynamic>;
      final events = (data['Events'] as List?) ?? const [];
      for (final e in events) {
        final id = (e['EventID'] as num?)?.toInt() ?? -1;
        if (id <= _lastEventId) continue;
        _lastEventId = id;

        final kind = _mapEvent(e['EventName'] as String? ?? '');
        if (kind != null) {
          _controller
              .add(GameEvent(gameId: gameId, kind: kind, meta: {'raw': e}));
        }
      }
    } catch (_) {
      // Match likely ended or API not ready; ignore and keep polling.
    }
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
