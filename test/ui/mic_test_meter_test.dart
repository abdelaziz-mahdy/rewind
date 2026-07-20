import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/theme.dart';
import 'package:rewind/src/ui/widgets/mic_test_meter.dart';

Widget _app(Widget child) => MaterialApp(
      theme: rewindTheme(),
      home: Scaffold(body: child),
    );

String _levelsJson({
  double micPeak = -120,
  double micMag = -120,
  double gamePeak = -120,
  double gameMag = -120,
}) =>
    '{"mic_peak_db":$micPeak,"mic_mag_db":$micMag,'
    '"game_peak_db":$gamePeak,"game_mag_db":$gameMag}';

void main() {
  group('AudioLevels.parse', () {
    test('parses the shim JSON shape', () {
      final l = AudioLevels.parse(_levelsJson(
          micPeak: -12.5, micMag: -20.1, gamePeak: -30.0, gameMag: -40.0));
      expect(l, isNotNull);
      expect(l!.micPeakDb, -12.5);
      expect(l.micMagDb, -20.1);
      expect(l.gamePeakDb, -30.0);
      expect(l.gameMagDb, -40.0);
    });

    test('null, malformed, and missing-field inputs all return null', () {
      expect(AudioLevels.parse(null), isNull);
      expect(AudioLevels.parse('not json'), isNull);
      expect(AudioLevels.parse('[]'), isNull);
      expect(AudioLevels.parse('{"mic_peak_db":-10}'), isNull);
    });

    test('gameActive only when game audio is meaningfully flowing', () {
      expect(AudioLevels.parse(_levelsJson(gamePeak: -20))!.gameActive, isTrue);
      expect(
          AudioLevels.parse(_levelsJson(gamePeak: -80))!.gameActive, isFalse);
    });
  });

  group('micTestVerdict', () {
    test('silence waits for speech', () {
      expect(micTestVerdict(-120), MicTestVerdict.waiting);
      expect(micTestVerdict(-60), MicTestVerdict.waiting);
    });

    test('quiet speech reads too quiet', () {
      expect(micTestVerdict(-40), MicTestVerdict.tooQuiet);
      expect(micTestVerdict(-23), MicTestVerdict.tooQuiet);
    });

    test('the target window reads good', () {
      expect(micTestVerdict(-20), MicTestVerdict.good);
      expect(micTestVerdict(-12), MicTestVerdict.good);
      expect(micTestVerdict(-6), MicTestVerdict.good);
    });

    test('hot and clipping levels warn', () {
      expect(micTestVerdict(-4), MicTestVerdict.tooLoud);
      expect(micTestVerdict(-1), MicTestVerdict.clipping);
      expect(micTestVerdict(0), MicTestVerdict.clipping);
    });
  });

  group('micTestHint', () {
    test('each verdict has a distinct actionable hint', () {
      expect(micTestHint(MicTestVerdict.waiting), contains('Speak'));
      expect(micTestHint(MicTestVerdict.tooQuiet), contains('raise Mic'));
      expect(micTestHint(MicTestVerdict.good), contains('good'));
      expect(micTestHint(MicTestVerdict.tooLoud), contains('lower Mic'));
      expect(micTestHint(MicTestVerdict.clipping), contains('Clipping'));
    });

    test('game comparison appends when game audio is flowing', () {
      expect(
        micTestHint(MicTestVerdict.good, voiceOverGameDb: 8),
        contains('8dB above the game'),
      );
      expect(
        micTestHint(MicTestVerdict.good, voiceOverGameDb: 1),
        contains('buried under the game'),
      );
      // While waiting there's no voice to compare — no game suffix.
      expect(
        micTestHint(MicTestVerdict.waiting, voiceOverGameDb: 8),
        isNot(contains('above the game')),
      );
    });
  });

  group('MicTestMeter widget', () {
    testWidgets('idle until the test button starts polling', (t) async {
      var polls = 0;
      await t.pumpWidget(_app(MicTestMeter(pollLevels: () {
        polls++;
        return _levelsJson();
      })));
      await t.pump(const Duration(milliseconds: 300));
      expect(polls, 0);
      expect(find.byKey(const ValueKey('micTestHint')), findsNothing);

      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump();
      expect(polls, greaterThan(0));

      // Stop cancels the timer so the test framework sees no pending timers.
      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump();
    });

    testWidgets('speaking at a good level shows the good hint', (t) async {
      await t.pumpWidget(_app(MicTestMeter(
        pollLevels: () => _levelsJson(micPeak: -12, micMag: -18),
      )));
      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Level looks good'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump();
    });

    testWidgets('null levels show the unavailable message', (t) async {
      await t.pumpWidget(_app(MicTestMeter(pollLevels: () => null)));
      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump(const Duration(milliseconds: 250));

      expect(find.textContaining('Levels unavailable'), findsOneWidget);

      await t.tap(find.byKey(const ValueKey('micTestButton')));
      await t.pump();
    });
  });
}
