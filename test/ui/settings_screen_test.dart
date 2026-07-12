import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/settings/app_settings.dart';
import 'package:rewind/src/ui/settings_screen.dart';
import 'package:rewind/src/ui/theme.dart';

Widget _app(Widget child) => MaterialApp(theme: rewindTheme(), home: child);

void main() {
  testWidgets(
      'invalid hotkey shows validation error and does not call onChanged',
      (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
    )));

    await t.enterText(find.byType(TextField).first, 'not a hotkey');
    await t.pump();

    expect(find.textContaining('Invalid hotkey'), findsOneWidget);
    expect(calls, isEmpty);
  });

  testWidgets('picking 60s updates settings via onChanged', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
    )));

    await t.tap(find.text('60 s'));
    await t.pump();

    expect(calls, isNotEmpty);
    expect(calls.last.defaultBufferSeconds, 60);
  });

  testWidgets('custom buffer clamps to 5..300', (t) async {
    final calls = <AppSettings>[];
    await t.pumpWidget(_app(SettingsScreen(
      settings: AppSettings(),
      onChanged: (s) async => calls.add(s),
    )));

    await t.tap(find.text('Custom'));
    await t.pump();

    final field = find.widgetWithText(TextField, 'Seconds (5-300)');
    expect(field, findsOneWidget);

    await t.enterText(field, '999');
    await t.pump();
    expect(calls.last.defaultBufferSeconds, 300);

    await t.enterText(field, '1');
    await t.pump();
    expect(calls.last.defaultBufferSeconds, 5);
  });
}
