import 'game_config.dart';

/// Global settings + per-game overrides.
class AppSettings {
  /// Default replay-buffer length when a game has no specific override.
  int defaultBufferSeconds;

  /// Global "clip that" hotkey (stored as a portable descriptor; the UI layer
  /// maps this to hotkey_manager). Example: "Alt+F10".
  String hotkey;

  final Map<String, GameConfig> _perGame;

  AppSettings({
    this.defaultBufferSeconds = 30,
    this.hotkey = 'Alt+F10',
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
        'perGame': _perGame.map((k, v) => MapEntry(k, v.toJson())),
      };

  factory AppSettings.fromJson(Map<String, dynamic> j) => AppSettings(
        defaultBufferSeconds: j['defaultBufferSeconds'] as int? ?? 30,
        hotkey: j['hotkey'] as String? ?? 'Alt+F10',
        perGame: ((j['perGame'] as Map?) ?? const {}).map(
          (k, v) => MapEntry(k as String,
              GameConfig.fromJson((v as Map).cast<String, dynamic>())),
        ),
      );
}
