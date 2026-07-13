import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/game_registry.dart';
import 'package:rewind/src/events/process_watcher_source.dart';

class FakeProcessLister implements ProcessLister {
  List<String> names = const [];
  Object? throwOnList;

  @override
  Future<List<String>> runningProcessNames() async {
    if (throwOnList != null) throw throwOnList!;
    return names;
  }
}

void main() {
  group('ProcessWatcherSource.isGameRunning', () {
    test('matches an exact process name', () async {
      final lister = FakeProcessLister()..names = ['MyGame.exe'];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame.exe',
        lister: lister,
      );

      expect(await source.isGameRunning(), isTrue);
    });

    test('matches a substring of a process name', () async {
      final lister = FakeProcessLister()..names = ['MyGameLauncher.exe'];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame',
        lister: lister,
      );

      expect(await source.isGameRunning(), isTrue);
    });

    test('matches case-insensitively', () async {
      final lister = FakeProcessLister()..names = ['mygame.exe'];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MYGAME',
        lister: lister,
      );

      expect(await source.isGameRunning(), isTrue);
    });

    test('matches basename of a full path', () async {
      final lister = FakeProcessLister()
        ..names = [r'C:\Program Files\MyGame\MyGame.exe'];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame.exe',
        lister: lister,
      );

      expect(await source.isGameRunning(), isTrue);
    });

    test('returns false when no process matches', () async {
      final lister = FakeProcessLister()..names = ['SomeOtherApp.exe'];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame',
        lister: lister,
      );

      expect(await source.isGameRunning(), isFalse);
    });

    test('returns false (never throws) when the lister throws', () async {
      final lister = FakeProcessLister()..throwOnList = Exception('boom');
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame',
        lister: lister,
      );

      expect(await source.isGameRunning(), isFalse);
    });
  });

  group('ProcessWatcherSource.events/start/stop', () {
    test('events stream is empty; start/stop toggle started flag', () async {
      final lister = FakeProcessLister();
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame',
        lister: lister,
      );

      final emitted = <Object>[];
      final sub = source.events().listen(emitted.add);

      expect(source.isStarted, isFalse);
      await source.start();
      expect(source.isStarted, isTrue);
      await source.stop();
      expect(source.isStarted, isFalse);

      await Future<void>.delayed(Duration.zero);
      expect(emitted, isEmpty);
      await sub.cancel();
    });
  });

  group('GameRegistry integration', () {
    test('activates and deactivates as the process appears/disappears',
        () async {
      final lister = FakeProcessLister()..names = [];
      final source = ProcessWatcherSource(
        gameId: 'app:mygame',
        displayName: 'My Game',
        processMatch: 'MyGame',
        lister: lister,
      );
      final registry = GameRegistry(sources: [source]);

      final activity = <GameActivity>[];
      final sub = registry.activity.listen(activity.add);

      // Not running yet.
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(activity, isEmpty);
      expect(registry.activeGameIds, isEmpty);

      // Process appears.
      lister.names = ['MyGame.exe'];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(activity, hasLength(1));
      expect(activity.single.gameId, 'app:mygame');
      expect(activity.single.active, isTrue);
      expect(registry.activeGameIds, contains('app:mygame'));
      expect(source.isStarted, isTrue);

      // Process disappears.
      lister.names = [];
      await registry.tickNow();
      await Future<void>.delayed(Duration.zero);
      expect(activity, hasLength(2));
      expect(activity.last.gameId, 'app:mygame');
      expect(activity.last.active, isFalse);
      expect(registry.activeGameIds, isEmpty);
      expect(source.isStarted, isFalse);

      await sub.cancel();
      await registry.dispose();
    });
  });

  group('SystemProcessLister', () {
    test('returns a non-empty list containing the current dart process',
        () async {
      const lister = SystemProcessLister();
      final names = await lister.runningProcessNames();

      expect(names, isNotEmpty);
      expect(
        names.any((n) => n.toLowerCase().contains('dart')),
        isTrue,
        reason: 'expected to find a "dart"-ish process among: $names',
      );
    });
  });
}
