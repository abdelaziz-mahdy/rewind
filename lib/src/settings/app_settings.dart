import 'game_config.dart';

/// Global settings + per-game overrides.
class AppSettings {
  /// Default replay-buffer length when a game has no specific override.
  int defaultBufferSeconds;

  /// Global "clip that" hotkey (stored as a portable descriptor; the UI layer
  /// maps this to hotkey_manager). Example: "Alt+F10".
  String hotkey;

  /// Global "start/stop recording" hotkey — same portable descriptor format
  /// as [hotkey], bound independently (see `HotkeyService.bindAll`).
  String recordHotkey;

  /// The display to capture, identified by a display uuid as reported by
  /// `CaptureEngine.listDisplays`. Null means "use the main display" (the
  /// capture engine's own default).
  String? captureDisplayUuid;

  /// The application to capture, identified by a bundle id as reported by
  /// `CaptureEngine.listCapturableApps`. Null means "capture the whole
  /// display" (per [captureDisplayUuid]) rather than a single app —
  /// `CaptureEngine.setCaptureApp(null)` is how the engine is told to
  /// revert.
  String? captureAppBundleId;

  /// Whether detecting a game becoming active should temporarily switch the
  /// capture target to that game's running app/window (reverting to
  /// [captureAppBundleId] — the persisted choice — when the game exits).
  /// This is a follow-the-game convenience, not a persisted capture
  /// preference; see `ClipCoordinator`. Defaults to on.
  bool autoSwitchCapture;

  final Map<String, GameConfig> _perGame;

  AppSettings({
    this.defaultBufferSeconds = 30,
    this.hotkey = 'Alt+F10',
    this.recordHotkey = 'Alt+F9',
    this.captureDisplayUuid,
    this.captureAppBundleId,
    this.autoSwitchCapture = true,
    Map<String, GameConfig>? perGame,
  }) : _perGame = perGame ?? {};

  /// Resolve config for a game, falling back to defaults.
  GameConfig configFor(String gameId) => _perGame.putIfAbsent(
        gameId,
        () => GameConfig(gameId: gameId, bufferSeconds: defaultBufferSeconds),
      );

  /// Read-only lookup: the per-game buffer length if a config already
  /// exists for [gameId], else [defaultBufferSeconds]. Unlike [configFor],
  /// this never creates/persists a row — safe to call from UI that must not
  /// pre-seed [allConfigs] (e.g. rendering the status strip before any game
  /// has been detected).
  int bufferSecondsFor(String? gameId) =>
      (gameId != null ? _perGame[gameId]?.bufferSeconds : null) ??
      defaultBufferSeconds;

  void setConfig(GameConfig config) => _perGame[config.gameId] = config;

  Iterable<GameConfig> get allConfigs => _perGame.values;

  Map<String, dynamic> toJson() => {
        'defaultBufferSeconds': defaultBufferSeconds,
        'hotkey': hotkey,
        'recordHotkey': recordHotkey,
        'captureDisplayUuid': captureDisplayUuid,
        'captureAppBundleId': captureAppBundleId,
        'autoSwitchCapture': autoSwitchCapture,
        'perGame': _perGame.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        defaultBufferSeconds: j['defaultBufferSeconds'] as int? ?? 30,
        hotkey: j['hotkey'] as String? ?? 'Alt+F10',
        recordHotkey: j['recordHotkey'] as String? ?? 'Alt+F9',
        captureDisplayUuid: j['captureDisplayUuid'] as String?,
        captureAppBundleId: j['captureAppBundleId'] as String?,
        autoSwitchCapture: j['autoSwitchCapture'] as bool? ?? true,
        perGame: ((j['perGame'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(k as String,
              GameConfig.fromJson((v as Map).cast<String, dynamic>())),
        ),
      );
}
