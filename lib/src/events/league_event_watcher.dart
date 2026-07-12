import 'dart:async';
import 'dart:convert';
import 'package:http/http.dart' as http;

import 'game_event.dart';
import 'game_event_source.dart';

/// Watches League of Legends via the local Live Client Data API.
///
/// While a match is running, the League client serves data on
/// https://127.0.0.1:2999 (self-signed cert; localhost only). We poll
/// `/liveclientdata/eventdata` and translate new events into [GameEvent]s.
///
/// NOTE: this is a scaffold. TODO(v0.2): handle the self-signed certificate,
/// de-duplicate events by EventID, and map multikills correctly.
class LeagueEventWatcher implements GameEventSource {
  static const _base = 'https://127.0.0.1:2999';
  static const _pollInterval = Duration(milliseconds: 500);

  final _controller = StreamController<GameEvent>.broadcast();
  Timer? _timer;
  int _lastEventId = -1;

  @override
  String get gameId => 'league_of_legends';

  @override
  String get displayName => 'League of Legends';

  @override
  Future<bool> isGameRunning() async {
    try {
      final res = await http
          .get(Uri.parse('$_base/liveclientdata/gamestats'))
          .timeout(const Duration(milliseconds: 400));
      return res.statusCode == 200;
    } catch (_) {
      return false; // API only exists mid-match; connection-refused is normal.
    }
  }

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
      final res = await http
          .get(Uri.parse('$_base/liveclientdata/eventdata'))
          .timeout(const Duration(milliseconds: 400));
      if (res.statusCode != 200) return;

      final data = jsonDecode(res.body) as Map<String, dynamic>;
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
