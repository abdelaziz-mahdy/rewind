import 'game_config.dart';

/// Fallback post-event quiet window (see [GameConfig.postEventSeconds] and
/// `ClipCoordinator.burstQuiet`'s doc) for a game with no per-game override.
/// A plain top-level constant, not an [AppSettings] field: unlike
/// [AppSettings.defaultBufferSeconds] this has no global user-facing
/// setting — the knob only ever lives on a game's MY GAMES page.
const defaultPostEventSeconds = 5;

/// What system/app sound is mixed into clips (separate from the microphone,
/// which is its own [AppSettings.captureMicrophone] toggle).
enum AudioMode {
  /// No system/app audio — silent clips unless the mic is on.
  off,

  /// Only the captured game/app's audio (excludes Discord, music, etc.).
  /// Needs an app/window capture source; falls back to silence without one.
  app,

  /// All desktop audio — every app's sound.
  all,
}

/// The shim's audio-mode int (see `rewind_set_audio_mode`).
int audioModeToShim(AudioMode m) => switch (m) {
      AudioMode.off => 0,
      AudioMode.all => 1,
      AudioMode.app => 2,
    };

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

  /// What system/app audio is captured — none, game/app only, or all
  /// desktop audio. Separate from [captureMicrophone]. Default [AudioMode.all].
  AudioMode audioMode;

  /// Whether the microphone is mixed into clips/recordings alongside the
  /// always-on system audio. Default OFF: capturing voice without an
  /// explicit opt-in is a privacy trap. First enable triggers the macOS
  /// microphone permission prompt.
  bool captureMicrophone;

  /// The microphone input device to use, identified by an
  /// `AudioInputInfo.uid` as reported by `CaptureEngine.listAudioInputs`.
  /// Null means "system default input" (the capture engine's own default).
  /// A saved uid for a device that's since been unplugged is NOT cleared —
  /// same philosophy as [captureAppBundleId]: the Settings dropdown just
  /// falls back to showing "System default" without touching the persisted
  /// choice, since the device may simply be disconnected, not permanently
  /// gone.
  String? micDeviceUid;

  /// Recording-level multiplier applied to the microphone source (see
  /// `rewind_set_mic_volume`): 1.0 = 100% (unity gain), clamped to 0.0-2.0.
  /// Default 1.0 — unchanged from every mic source's natural level.
  double micVolume;

  /// Recording-level multiplier applied to the desktop/game-audio source
  /// (see `rewind_set_game_volume`), the same lever as [micVolume] but
  /// against game audio instead of the mic — pulls game audio down under
  /// voice. 1.0 = 100% (unity gain), clamped to 0.0-2.0. Default 1.0.
  double gameAudioVolume;

  /// Whether the mic auto-leveling filter chain (compressor->limiter, see
  /// `rewind_set_mic_leveling`) is on — evens out voice so it sits
  /// consistently against the game rather than swinging between too quiet
  /// and too loud. Default TRUE: this is the "set once, forget" feature's
  /// whole point, so it's on from first launch, not an opt-in.
  bool micAutoLevel;

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

  /// Whether the replay buffer should auto-pause whenever NO game is
  /// detected, and resume the moment one activates — killing the always-on
  /// desktop capture load for users who only ever want game footage.
  /// Default ON as of 2026-07-18 (deliberately flipped from the original
  /// OFF default): pausing at the desktop is now the product's default
  /// pitch, not an opt-in — a settings file predating this key gets the
  /// new behavior too, same as a fresh install, unless the user already
  /// persisted an explicit `false` by toggling it off. Onboarding's "Try it
  /// now" step overrides this WHILE VISIBLE (see `main.dart`'s
  /// `onboardingActive`) so its desktop save still works. See
  /// `main.dart`'s `applyBufferPolicy` — the single buffer-control point
  /// this setting feeds into, alongside the tray's manual Pause/Resume.
  bool captureOnlyInGame;

  /// The user's Steam id64 (17-digit numeric), or a vanity name/profile URL
  /// normalized down to its trailing segment at save time (see
  /// `SettingsScreen`'s SteamID field) — `SteamAchievementWatcher` resolves
  /// a non-numeric value via `ISteamUser/ResolveVanityURL` itself. UNUSED by
  /// the keyless local trigger path (`SteamStatsWatcher`, which discovers
  /// accounts itself from Steam's own `loginusers.vdf` — see
  /// docs/COMPLIANCE.md); kept for the optional, currently-unbuilt web
  /// watcher's possible future enrichment. Empty string (the default) means
  /// "not configured".
  String steamId64;

  /// A Steam Web API key (steamcommunity.com/dev/apikey). Stored locally in
  /// settings.json only — never sent anywhere but api.steampowered.com as a
  /// query param, per that API's own auth scheme. Same "unused today" status
  /// as [steamId64] — see its doc. Empty string (the default) means "not
  /// configured".
  String steamWebApiKey;

  /// Whether a new Steam achievement unlock should auto-clip. Default TRUE:
  /// gates `SteamStatsWatcher`, which needs no credentials and exists
  /// unconditionally, so unlike the retired credential-gated design a
  /// default-on toggle IS live from first launch (as soon as the watcher's
  /// local discovery finds a Steam install with a logged-in account).
  bool clipSteamAchievements;

  /// Whether MANUAL save/record actions play a short confirmation sound
  /// (see `ClipSounds`, `ClipCoordinator.sounds`) — success/failure on a
  /// hotkey save, start/stop on a manual recording. Auto-clipped events
  /// never sound regardless of this setting. Default ON.
  bool playFeedbackSounds;

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
    // 1080 (the Balanced tier), NOT null/native: <5% of users ever change a
    // default, and native-by-default silently eats disk on Retina/1440p rigs
    // (see VideoPreset's doc). Existing settings files are unaffected —
    // fromJson reads their stored value, including a deliberate null=Source.
    this.captureMaxHeight = 1080,
    this.audioMode = AudioMode.all,
    this.captureMicrophone = false,
    this.micDeviceUid,
    this.micVolume = 1.0,
    this.gameAudioVolume = 1.0,
    this.micAutoLevel = true,
    this.maxStorageGb = 20,
    this.maxClipAgeDays,
    this.onboardingComplete = false,
    this.clipsDirPath,
    this.captureOnlyInGame = true,
    this.steamId64 = '',
    this.steamWebApiKey = '',
    this.clipSteamAchievements = true,
    this.playFeedbackSounds = true,
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

  /// Read-only lookup: the per-game post-event quiet window (see
  /// [GameConfig.postEventSeconds]) if a config already exists for
  /// [gameId], else [defaultPostEventSeconds]. Mirrors [bufferSecondsFor] —
  /// never creates/persists a row.
  int postEventSecondsFor(String? gameId) =>
      (gameId != null ? _perGame[gameId]?.postEventSeconds : null) ??
      defaultPostEventSeconds;

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
        'audioMode': audioMode.name,
        'captureMicrophone': captureMicrophone,
        'micDeviceUid': micDeviceUid,
        'micVolume': micVolume,
        'gameAudioVolume': gameAudioVolume,
        'micAutoLevel': micAutoLevel,
        'maxStorageGb': maxStorageGb,
        'maxClipAgeDays': maxClipAgeDays,
        'onboardingComplete': onboardingComplete,
        'clipsDirPath': clipsDirPath,
        'captureOnlyInGame': captureOnlyInGame,
        'steamId64': steamId64,
        'steamWebApiKey': steamWebApiKey,
        'clipSteamAchievements': clipSteamAchievements,
        'playFeedbackSounds': playFeedbackSounds,
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
        audioMode: _audioModeFromJson(j),
        captureMicrophone: j['captureMicrophone'] as bool? ?? false,
        micDeviceUid: j['micDeviceUid'] as String?,
        // Clamp on load: a hand-edited or otherwise out-of-range stored
        // value must not reach the shim, which clamps too but has no way to
        // report that back up to Settings' live percent label.
        micVolume:
            ((j['micVolume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 2.0),
        // Same clamp-on-load discipline as micVolume above.
        gameAudioVolume:
            ((j['gameAudioVolume'] as num?)?.toDouble() ?? 1.0).clamp(0.0, 2.0),
        // Absent key (a settings file predating this feature) falls back to
        // ON — the feature's whole point is "set once, forget", so a fresh
        // install and an existing settings file both start auto-leveled.
        micAutoLevel: j['micAutoLevel'] as bool? ?? true,
        // A stored null is a deliberate "unlimited" choice and must survive
        // the round-trip; only a MISSING key (pre-cleanup settings file)
        // falls back to the 20 GB default.
        maxStorageGb:
            j.containsKey('maxStorageGb') ? j['maxStorageGb'] as int? : 20,
        maxClipAgeDays: j['maxClipAgeDays'] as int?,
        onboardingComplete: j['onboardingComplete'] as bool? ?? false,
        clipsDirPath: j['clipsDirPath'] as String?,
        // Absent key (a settings file predating this feature, or predating
        // the 2026-07-18 default flip) falls back to ON — the same default
        // as a fresh install.
        captureOnlyInGame: j['captureOnlyInGame'] as bool? ?? true,
        steamId64: j['steamId64'] as String? ?? '',
        steamWebApiKey: j['steamWebApiKey'] as String? ?? '',
        clipSteamAchievements: j['clipSteamAchievements'] as bool? ?? true,
        // Absent key (a settings file predating this feature) falls back to
        // ON — the same default as a fresh install.
        playFeedbackSounds: j['playFeedbackSounds'] as bool? ?? true,
        perGame: ((j['perGame'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(k as String,
              GameConfig.fromJson((v as Map).cast<String, dynamic>())),
        ),
      );

  /// Reads [audioMode], migrating the old boolean `captureSystemAudio`
  /// (false → off, true → all) so existing settings files keep working.
  static AudioMode _audioModeFromJson(Map<String, dynamic> j) {
    final name = j['audioMode'] as String?;
    if (name != null) {
      return AudioMode.values
          .firstWhere((m) => m.name == name, orElse: () => AudioMode.all);
    }
    final legacy = j['captureSystemAudio'] as bool?;
    if (legacy != null) return legacy ? AudioMode.all : AudioMode.off;
    return AudioMode.all;
  }
}
