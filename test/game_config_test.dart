import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/settings/game_config.dart';

void main() {
  group('GameConfig.recordFullSession', () {
    test('defaults to false', () {
      expect(GameConfig(gameId: 'app:x').recordFullSession, isFalse);
    });

    test('round-trips through toJson/fromJson', () {
      final cfg = GameConfig(gameId: 'app:x', recordFullSession: true);
      final loaded = GameConfig.fromJson(cfg.toJson());
      expect(loaded.recordFullSession, isTrue);
    });

    test('absent key (settings predating the feature) reads as false', () {
      final loaded = GameConfig.fromJson({
        'gameId': 'app:x',
        'bufferSeconds': 30,
        'autoClip': true,
        'enabledEvents': const <String>[],
        // no recordFullSession key
      });
      expect(loaded.recordFullSession, isFalse);
    });
  });
}
