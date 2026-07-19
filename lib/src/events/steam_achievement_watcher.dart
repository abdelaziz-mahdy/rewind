import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../log/log.dart';
import '../settings/app_settings.dart';
import 'game_event.dart';
import 'game_event_source.dart';

/// The result of one Steam Web API request: the raw HTTP status code plus
/// the response body. Steam distinguishes failure modes by STATUS (403 for
/// a bad key) as much as by body content (`success: false` for a private
/// profile), so — unlike `LeagueEventWatcher`'s body-or-null transport,
/// which only ever needs to tell "200" from "anything else" — the injectable
/// transport here has to carry the status code through. `body` is null only
/// when the response genuinely had none; a non-200 status can still carry a
/// body (Steam sometimes does), so it's not collapsed away.
class SteamHttpResponse {
  final int statusCode;
  final String? body;
  const SteamHttpResponse(this.statusCode, this.body);
}

/// Polls the official Steam Web API for achievement unlocks in whatever
/// Steam game the user is currently playing — a generic integration that
/// works for EVERY Steam game, unlike `LeagueEventWatcher`'s one-game local
/// API. Sanctioned sources only (see docs/COMPLIANCE.md): `api.steampowered.
/// com` with a user-supplied key + steamid as query params, nothing else.
///
/// This is the THIRD `GameEventSource` shape (see ARCHITECTURE.md's events
/// layer): League polls a local, cert-pinned HTTPS endpoint that requires no
/// credentials; this polls a public HTTPS endpoint that requires a key +
/// steamid the user supplies. The two integrations share little beyond the
/// interface itself (see [isGameRunning]'s doc for the biggest divergence),
/// so — per the YAGNI note in ARCHITECTURE.md — nothing is extracted into a
/// shared base class yet.
///
/// Two tiers of polling, both re-entrancy-guarded like
/// `LeagueEventWatcher._poll`:
///  1. **Presence** ([presencePollInterval], default 20 s): `
///     GetPlayerSummaries` — is the user in a game, and which appid.
///  2. **Achievements** ([achievementPollInterval], default 15 s), only
///     while presence says "in a game": `GetPlayerAchievements` for that
///     appid.
///
/// [isGameRunning] always answers `false` — this source never "activates"
/// the way `LeagueEventWatcher`/`ProcessWatcherSource` do (see that
/// getter's doc for what that means for `GameRegistry`/`ClipCoordinator`).
/// It is purely an event emitter, driven entirely by its own [start]/[stop]
/// lifecycle.
///
/// **The League 44 MB lesson applies again:** the FIRST achievement poll of
/// a (game session, appid) pair only SEEDS the currently-unlocked set — it
/// must never replay a game's whole achievement history as clips the
/// moment Rewind starts watching it.
///
/// RETIRED as the trigger path (maintainer decision 2026-07-19): `source_
/// builder.dart` no longer constructs this class — `SteamStatsWatcher`
/// (steam_stats_watcher.dart) replaced it with keyless, local, read-only
/// detection off Steam's own stats cache, needing no API key and no
/// network. This class stays in the tree, compiling and tested, purely as a
/// seam for POSSIBLE future enrichment (a field the local cache doesn't
/// carry, e.g. a global unlock-rate stat) — it is not started by anything
/// today. See docs/COMPLIANCE.md's Steam entry for the full reasoning.
class SteamAchievementWatcher implements GameEventSource {
  static const _apiHost = 'api.steampowered.com';
  static const _requestTimeout = Duration(seconds: 10);
  static const _maxBackoff = Duration(minutes: 5);

  static final HttpClient _client = HttpClient()
    ..connectionTimeout = _requestTimeout;

  /// GETs a Steam Web API url, returning its status+body on any response
  /// Steam actually sends, and null only on a genuine transport failure
  /// (unreachable, timeout, malformed response) — the signal
  /// [_onFailure]'s backoff and the "Steam unreachable" status are keyed on.
  static Future<SteamHttpResponse?> _httpFetch(Uri uri) async {
    try {
      final req = await _client.getUrl(uri).timeout(_requestTimeout);
      final res = await req.close().timeout(_requestTimeout);
      final body = await utf8.decoder.bind(res).join().timeout(_requestTimeout);
      return SteamHttpResponse(res.statusCode, body);
    } catch (_) {
      return null;
    }
  }

  /// The live app settings — read fresh on every poll rather than snapshot
  /// at construction, so an edited API key/Steam ID or a flipped
  /// `clipSteamAchievements` toggle takes effect on the very next tick with
  /// no rebuild/restart needed. See `source_builder.dart`'s doc for why this
  /// is the credentials-change wiring choice.
  final AppSettings settings;

  final Duration presencePollInterval;
  final Duration achievementPollInterval;
  final Future<SteamHttpResponse?> Function(Uri) _fetch;

  /// Resolves the currently-active DETECTED game (set by `main.dart` to
  /// `() => coordinator.activeGame.value` once the coordinator exists — this
  /// source has no such reference at construction time). Null (the default,
  /// and whenever it returns null) falls back to `steam:<appid>` — see
  /// [_doAchievementPoll].
  String? Function()? resolveGameId;

  SteamAchievementWatcher({
    required this.settings,
    this.presencePollInterval = const Duration(seconds: 20),
    this.achievementPollInterval = const Duration(seconds: 15),
    Future<SteamHttpResponse?> Function(Uri)? fetch,
    this.resolveGameId,
  }) : _fetch = fetch ?? _httpFetch;

  final _controller = StreamController<GameEvent>.broadcast();

  /// UI-facing status line (`SettingsScreen`'s Steam tab) — null means
  /// idle/off (no credentials configured). See the class doc's status list.
  final ValueNotifier<String?> status = ValueNotifier(null);

  Timer? _presenceTimer;
  Timer? _achievementTimer;
  bool _presencePolling = false;
  bool _achievementPolling = false;

  /// The appid presence currently reports the user playing, or null when no
  /// Steam game is detected. Drives the achievement timer's lifecycle.
  int? _currentAppId;

  /// Whether the currently-unlocked set has been SEEDED for
  /// [_currentAppId] yet (see the class doc's "44 MB lesson").
  bool _seededForCurrentApp = false;

  /// Achievement `apiname`s already known unlocked for [_currentAppId] —
  /// seeded on first poll, then diffed every poll after.
  final Set<String> _unlockedApiNames = {};

  /// `apiname` -> real display name, cached per appid (`GetSchemaForGame`
  /// rarely changes and costs a whole extra request otherwise).
  final Map<int, Map<String, String>> _schemaCache = {};

  /// The id64 currently in effect for [settings.steamId64] — either that
  /// value verbatim (already 17-digit numeric) or the cached resolution of
  /// it as a vanity name (see [_resolveEffectiveId64]). Refreshed every
  /// presence poll; read directly by [_doAchievementPoll] so it works either
  /// way without re-deriving it.
  String? _currentId64;
  String? _vanityResolvedFrom;
  String? _vanityResolvedId64;

  int _consecutiveFailures = 0;
  DateTime? _backoffUntil;

  @override
  String get gameId => 'steam';

  @override
  String get displayName => 'Steam';

  /// Always false — deliberately. Unlike `LeagueEventWatcher` (whose
  /// match-live activation IS `GameRegistry`'s activation signal), this
  /// source's "is something happening" state (in a game / not) never needs
  /// to reach `ClipCoordinator.activeGame`/`activeGameIds`/the buffer
  /// policy/capture auto-switch — an achievement clip is attributed to
  /// whatever game the REST of the app already detected active (see
  /// [resolveGameId]), not to this source. Returning `false` here means
  /// `GameRegistry._tick` never calls [start]/[stop] on this source itself
  /// (see that class's `_mergeEventsOf` doc for how its events still reach
  /// the coordinator regardless) — [start] is called directly by
  /// `main.dart` instead, right after construction.
  @override
  Future<bool> isGameRunning() async => false;

  /// Moot given [isGameRunning] is always false (this source never
  /// activates, so nothing ever reads this) — left at the interface
  /// default rather than removed, since a future refactor that DID gate
  /// activation on something real for this source should get sane behavior
  /// for free.
  @override
  bool get countsAsPlaying => true;

  @override
  String? get processMatch => null;

  @override
  Stream<GameEvent> events() => _controller.stream;

  @override
  Future<void> start() async {
    _presenceTimer ??=
        Timer.periodic(presencePollInterval, (_) => pollPresenceNow());
  }

  @override
  Future<void> stop() async {
    _presenceTimer?.cancel();
    _presenceTimer = null;
    _resetGameSession();
    _consecutiveFailures = 0;
    _backoffUntil = null;
    status.value = null;
  }

  void _resetGameSession() {
    _achievementTimer?.cancel();
    _achievementTimer = null;
    _currentAppId = null;
    _seededForCurrentApp = false;
    _unlockedApiNames.clear();
  }

  /// Visible for tests: one presence-poll cycle, exactly what the periodic
  /// timer runs.
  Future<void> pollPresenceNow() async {
    if (_presencePolling) return;
    _presencePolling = true;
    try {
      await _doPresencePoll();
    } finally {
      _presencePolling = false;
    }
  }

  /// Visible for tests: one achievement-poll cycle. No-ops when no Steam
  /// game is currently detected (see [_currentAppId]).
  Future<void> pollAchievementsNow() async {
    final appId = _currentAppId;
    if (appId == null) return;
    if (_achievementPolling) return;
    _achievementPolling = true;
    try {
      await _doAchievementPoll(appId);
    } finally {
      _achievementPolling = false;
    }
  }

  Future<void> _doPresencePoll() async {
    final id64Input = settings.steamId64.trim();
    final key = settings.steamWebApiKey.trim();
    if (id64Input.isEmpty || key.isEmpty) {
      status.value = null;
      _resetGameSession();
      return;
    }
    if (_backoffUntil case final until? when DateTime.now().isBefore(until)) {
      return; // cooling down; try again next tick
    }

    try {
      final id64 = await _resolveEffectiveId64(id64Input, key);
      if (id64 == null) {
        status.value = "Couldn't resolve Steam ID";
        _onFailure();
        return;
      }

      final resp = await _fetch(Uri.https(
        _apiHost,
        '/ISteamUser/GetPlayerSummaries/v0002/',
        {'key': key, 'steamids': id64},
      ));
      if (resp == null) {
        status.value = 'Steam unreachable — retrying';
        _onFailure();
        return;
      }
      if (resp.statusCode == 403) {
        status.value = 'Invalid API key';
        _onFailure();
        return;
      }
      if (resp.statusCode != 200) {
        status.value = 'Steam unreachable — retrying';
        _onFailure();
        return;
      }

      final json = jsonDecode(resp.body ?? '') as Map<String, dynamic>;
      final players =
          ((json['response'] as Map?)?['players'] as List?) ?? const [];
      if (players.isEmpty) {
        status.value = 'Steam profile not found — check the Steam ID';
        _onFailure();
        return;
      }
      _onSuccess();

      final player = (players.first as Map).cast<String, dynamic>();
      final appIdStr = player['gameid'] as String?;
      final appId = appIdStr != null ? int.tryParse(appIdStr) : null;
      if (appId == null) {
        status.value = 'Waiting for a Steam game';
        _resetGameSession();
        return;
      }

      final gameName = player['gameextrainfo'] as String? ?? 'a game';
      // Set BEFORE the immediate achievement check below, not after: that
      // check can overwrite this with a more specific status ("Invalid API
      // key", the private-profile message) and must win — a stale
      // "Watching" would otherwise paper over a real problem the very same
      // tick it's discovered.
      status.value = 'Watching (in $gameName)';
      if (appId != _currentAppId) {
        // New (appid, session) pair: reset and seed on the very next
        // achievement poll — never assume the old appid's unlocked set
        // still applies.
        _currentAppId = appId;
        _seededForCurrentApp = false;
        _unlockedApiNames.clear();
        _achievementTimer?.cancel();
        _achievementTimer = Timer.periodic(
            achievementPollInterval, (_) => pollAchievementsNow());
        // Presence JUST told us there's a game to check — don't make the
        // first achievement check wait out a whole achievementPollInterval
        // on top of this tick (interpretation of the brief's "skip if
        // presence already implies a poll this tick": the redundant wait is
        // what's skipped, not the check itself). Awaited (not fire-and-
        // forget) so this counts as part of THIS tick's work, deterministic
        // for callers/tests the same way the rest of this method is.
        await pollAchievementsNow();
      }
    } catch (err, stack) {
      talker.handle(err, stack);
      status.value = 'Steam unreachable — retrying';
      _onFailure();
    }
  }

  Future<void> _doAchievementPoll(int appId) async {
    final key = settings.steamWebApiKey.trim();
    final id64 = _currentId64;
    if (key.isEmpty || id64 == null) return; // presence poll owns status

    if (_backoffUntil case final until? when DateTime.now().isBefore(until)) {
      return;
    }

    try {
      final resp = await _fetch(Uri.https(
        _apiHost,
        '/ISteamUserStats/GetPlayerAchievements/v0001/',
        {'key': key, 'steamid': id64, 'appid': '$appId'},
      ));
      if (resp == null) {
        status.value = 'Steam unreachable — retrying';
        _onFailure();
        return;
      }
      if (resp.statusCode == 403) {
        status.value = 'Invalid API key';
        _onFailure();
        return;
      }
      if (resp.statusCode != 200) {
        status.value = 'Steam unreachable — retrying';
        _onFailure();
        return;
      }

      final json = jsonDecode(resp.body ?? '') as Map<String, dynamic>;
      final playerstats =
          (json['playerstats'] as Map?)?.cast<String, dynamic>();
      if (playerstats == null) {
        status.value = 'Steam unreachable — retrying';
        _onFailure();
        return;
      }
      final success = playerstats['success'] == true;
      if (!success) {
        // A real, definitive answer — not a network hiccup — so this
        // resets backoff/failure count even though it's not a "watching"
        // state: Steam responded fine, the DATA says the profile's game
        // details are private (verified against community API docs: this
        // is the documented shape for that case, `error: "Profile is not
        // public"`, `success: false`, no `achievements` array).
        _onSuccess();
        status.value = 'Steam profile is private — set Game details to '
            'Public';
        return;
      }
      _onSuccess();

      final achievements = ((playerstats['achievements'] as List?) ?? const [])
          .map((a) => (a as Map).cast<String, dynamic>())
          .toList();

      if (!_seededForCurrentApp) {
        // First poll of this (appid, session): seed past whatever's already
        // unlocked and emit NOTHING — see the class doc's 44 MB lesson.
        // Fail closed: a malformed entry is simply skipped, never guessed.
        for (final a in achievements) {
          if ((a['achieved'] as num?)?.toInt() == 1) {
            final name = a['apiname'] as String?;
            if (name != null) _unlockedApiNames.add(name);
          }
        }
        _seededForCurrentApp = true;
        return;
      }

      for (final a in achievements) {
        final name = a['apiname'] as String?;
        final achieved = (a['achieved'] as num?)?.toInt() == 1;
        if (name == null || !achieved || _unlockedApiNames.contains(name)) {
          continue;
        }
        _unlockedApiNames.add(name);
        // Fail closed on the GLOBAL toggle too: still marks it unlocked
        // above (so re-enabling the toggle later doesn't replay it as
        // "new"), just never emits while it's off.
        if (!settings.clipSteamAchievements) continue;

        final label = await _displayNameFor(appId, name, key);
        talker.info('Steam: achievement unlocked ($label, appid $appId)');
        _controller.add(GameEvent(
          gameId: resolveGameId?.call() ?? 'steam:$appId',
          kind: GameEventKind.achievement,
          meta: {'label': label, 'appId': appId, 'apiName': name},
        ));
      }
    } catch (err, stack) {
      talker.handle(err, stack);
      status.value = 'Steam unreachable — retrying';
      _onFailure();
    }
  }

  /// The achievement's real display name from `GetSchemaForGame` (cached
  /// per appid), falling back to the raw `apiname` if the schema fetch
  /// fails — a schema hiccup should never withhold the clip itself, just
  /// its prettiest label.
  Future<String> _displayNameFor(int appId, String apiName, String key) async {
    final cached = _schemaCache[appId];
    if (cached != null) return cached[apiName] ?? apiName;
    final schema = await _fetchSchema(appId, key);
    _schemaCache[appId] = schema;
    return schema[apiName] ?? apiName;
  }

  Future<Map<String, String>> _fetchSchema(int appId, String key) async {
    try {
      final resp = await _fetch(Uri.https(
        _apiHost,
        '/ISteamUserStats/GetSchemaForGame/v2/',
        {'key': key, 'appid': '$appId'},
      ));
      if (resp == null || resp.statusCode != 200 || resp.body == null) {
        return const {};
      }
      final json = jsonDecode(resp.body!) as Map<String, dynamic>;
      final stats = (json['game'] as Map?)?['availableGameStats']
          as Map<String, dynamic>?;
      final list = (stats?['achievements'] as List?) ?? const [];
      return {
        for (final raw in list)
          if ((raw as Map)['name'] is String && raw['displayName'] is String)
            raw['name'] as String: raw['displayName'] as String,
      };
    } catch (_) {
      return const {};
    }
  }

  static final _id64Pattern = RegExp(r'^\d{17}$');

  /// Resolves [input] to a real id64, caching the result on [_currentId64]
  /// either way (verbatim numeric input, or a vanity resolution) so
  /// [_doAchievementPoll] can read one field regardless of which path was
  /// taken. Re-resolves a vanity name only when [input] itself changes —
  /// cheap, since Steam ids don't change once resolved.
  Future<String?> _resolveEffectiveId64(String input, String key) async {
    if (_id64Pattern.hasMatch(input)) {
      _currentId64 = input;
      return input;
    }
    if (_vanityResolvedFrom == input && _vanityResolvedId64 != null) {
      _currentId64 = _vanityResolvedId64;
      return _vanityResolvedId64;
    }
    final resp = await _fetch(Uri.https(
      _apiHost,
      '/ISteamUser/ResolveVanityURL/v0001/',
      {'key': key, 'vanityurl': input},
    ));
    if (resp == null || resp.statusCode != 200 || resp.body == null) {
      return null;
    }
    try {
      final json = jsonDecode(resp.body!) as Map<String, dynamic>;
      final response = json['response'] as Map<String, dynamic>?;
      if ((response?['success'] as num?)?.toInt() != 1) return null;
      final id = response?['steamid'] as String?;
      if (id == null) return null;
      _vanityResolvedFrom = input;
      _vanityResolvedId64 = id;
      _currentId64 = id;
      return id;
    } catch (_) {
      return null;
    }
  }

  void _onFailure() {
    _consecutiveFailures++;
    final seconds = 5 * (1 << (_consecutiveFailures - 1).clamp(0, 6));
    final backoff = Duration(seconds: seconds);
    _backoffUntil =
        DateTime.now().add(backoff > _maxBackoff ? _maxBackoff : backoff);
  }

  void _onSuccess() {
    _consecutiveFailures = 0;
    _backoffUntil = null;
  }
}
