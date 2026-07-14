import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_registry.dart';

import 'fakes/fake_game_source.dart';

void main() {
  group('GameRegistry.addNewSources', () {
    test('adopts sources with unseen gameIds, skips already-supervised ones',
        () {
      final existing = FakeGameSource('app:already_here');
      final registry = GameRegistry(sources: [existing]);

      final fresh = FakeGameSource('app:brand_new');
      final dup = FakeGameSource('app:already_here', 'Impostor');
      registry.addNewSources([fresh, dup]);

      expect(registry.sources, hasLength(2));
      expect(registry.sources, contains(fresh));
      expect(registry.sources, contains(existing));
      expect(registry.sources, isNot(contains(dup)));
    });

    test('an adopted source is supervised by the very next tick (live add)',
        () async {
      final registry = GameRegistry(sources: []);
      final game = FakeGameSource('app:added_mid_session')..running = true;

      registry.addNewSources([game]);
      await registry.tickNow();

      expect(registry.activeGameIds, contains('app:added_mid_session'));
    });
  });
}
