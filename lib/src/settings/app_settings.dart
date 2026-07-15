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

  /// Display name of the picked capture app, stored alongside
  /// [captureAppBundleId] because a bundle id alone can be ambiguous:
  /// every Windows program running under CrossOver/Wine shares the
  /// translator's bundle id, so a bundle-id lookup against the app list
  /// can't tell "PenguinHotel-Win64-Shipping" from "CrossOver". Purely a
  /// label — the engine still targets [captureAppBundleId].
  String? captureAppName;

  /// Whether detecting a game becoming active should temporarily switch the
  /// capture target to that game's running app/window (reverting to
  /// [captureAppBundleId] — the persisted choice — when the game exits).
  /// This is a follow-the-game convenience, not a persisted capture
  /// preference; see `ClipCoordinator`. Defaults to on.
  bool autoSwitchCapture;

  /// Capture framerate (30 or 60). Higher = smoother clips but more CPU and
  /// disk. Applied when capture starts (next launch).
  int captureFps;

  /// Output-height cap: null/0 = source resolution, else 720/1080/1440.
  /// Downscales tall displays to save CPU and disk (aspect preserved).
  /// Applied when capture starts (next launch).
  int? captureMaxHeight;

  /// Whether system/desktop audio (every app's sound) is captured. Default
  /// on. Turn off if you don't want other apps (Discord, music) in your
  /// clips — pair with [captureMicrophone] for voice-only.
  bool captureSystemAudio;

  /// Whether the microphone is mixed into clips/recordings alongside the
  /// always-on system audio. Default OFF: capturing voice without an
  /// explicit opt-in is a privacy trap. First enable triggers the macOS
  /// microphone permission prompt.
  bool captureMicrophone;

  /// Auto-cleanup: cap on total clip storage, in whole GB. Null means
  /// UNLIMITED (cleanup by size off). Defaults to 20 — the pre-existing
  /// hardcoded `RetentionPolicy.twentyGb` behavior, now user-visible.
  /// Enforced by `StorageManager` (oldest unprotected clips first).
  int? maxStorageGb;

  /// Auto-cleanup: delete unprotected clips older than this many days.
  /// Null means NEVER (age cleanup off — the default).
  int? maxClipAgeDays;

  /// Whether the first-run getting-started guide has been completed (or
  /// skipped). False shows it on launch; the guide is re-openable from
  /// Settings regardless.
  bool onboardingComplete;

  /// Custom recordings folder. Null means the per-OS default
  /// (`~/Movies/Rewind` on macOS — see `clips_dir.dart`). Applied at
  /// startup: the capture engine, clip library, and debug triggers are all
  /// bound to it, so a change takes effect on the next launch (Settings
  /// says so next to the field).
  String? clipsDirPath;

  final Map<String, GameConfig> _perGame;

  AppSettings({
    this.defaultBufferSeconds = 30,
    this.hotkey = 'Alt+F10',
    this.recordHotkey = 'Alt+F9',
    this.captureDisplayUuid,
    this.captureAppBundleId,
    this.captureAppName,
    this.autoSwitchCapture = true,
    this.captureFps = 60,
    this.captureMaxHeight,
    this.captureSystemAudio = true,
    this.captureMicrophone = false,
    this.maxStorageGb = 20,
    this.maxClipAgeDays,
    this.onboardingComplete = false,
    this.clipsDirPath,
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
        'captureAppName': captureAppName,
        'autoSwitchCapture': autoSwitchCapture,
        'captureFps': captureFps,
        'captureMaxHeight': captureMaxHeight,
        'captureSystemAudio': captureSystemAudio,
        'captureMicrophone': captureMicrophone,
        'maxStorageGb': maxStorageGb,
        'maxClipAgeDays': maxClipAgeDays,
        'onboardingComplete': onboardingComplete,
        'clipsDirPath': clipsDirPath,
        'perGame': _perGame.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        defaultBufferSeconds: j['defaultBufferSeconds'] as int? ?? 30,
        hotkey: j['hotkey'] as String? ?? 'Alt+F10',
        recordHotkey: j['recordHotkey'] as String? ?? 'Alt+F9',
        captureDisplayUuid: j['captureDisplayUuid'] as String?,
        captureAppBundleId: j['captureAppBundleId'] as String?,
        captureAppName: j['captureAppName'] as String?,
        autoSwitchCapture: j['autoSwitchCapture'] as bool? ?? true,
        captureFps: j['captureFps'] as int? ?? 60,
        captureMaxHeight: j['captureMaxHeight'] as int?,
        captureSystemAudio: j['captureSystemAudio'] as bool? ?? true,
        captureMicrophone: j['captureMicrophone'] as bool? ?? false,
        // A stored null is a deliberate "unlimited" choice and must survive
        // the round-trip; only a MISSING key (pre-cleanup settings file)
        // falls back to the 20 GB default.
        maxStorageGb:
            j.containsKey('maxStorageGb') ? j['maxStorageGb'] as int? : 20,
        maxClipAgeDays: j['maxClipAgeDays'] as int?,
        onboardingComplete: j['onboardingComplete'] as bool? ?? false,
        clipsDirPath: j['clipsDirPath'] as String?,
        perGame: ((j['perGame'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(k as String,
              GameConfig.fromJson((v as Map).cast<String, dynamic>())),
        ),
      );
}
