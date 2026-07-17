import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/widgets/dragon_art.dart';

/// A real, fully-decodable 1×1 transparent PNG — `Image.file` needs an
/// actual decode, not just valid magic bytes (see
/// `test/ui/widgets/game_tile_avatar_test.dart` for the same fixture and
/// why).
final _tinyPng = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVR42mNk+A8A'
    'AQUBAScY42YAAAAASUVORK5CYII=');

void main() {
  late Directory tmp;

  setUp(() => tmp = Directory.systemTemp.createTempSync('rewind_dragon_art'));
  tearDown(() {
    try {
      tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // best-effort
    }
  });

  Widget app(Widget child) => MaterialApp(home: Scaffold(body: child));

  testWidgets('null future renders the placeholder immediately', (t) async {
    await t.pumpWidget(app(const DragonArt(
      future: null,
      size: 32,
      placeholder: Text('placeholder'),
    )));

    expect(find.text('placeholder'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets(
      'a future resolving to null renders the placeholder, never a broken '
      'image', (t) async {
    await t.pumpWidget(app(DragonArt(
      future: Future<File?>.value(null),
      size: 32,
      placeholder: const Text('placeholder'),
    )));
    await t.pump();

    expect(find.text('placeholder'), findsOneWidget);
    expect(find.byType(Image), findsNothing);
  });

  testWidgets(
      'a future resolving to a real file swaps to the image, replacing the '
      'placeholder', (t) async {
    // Written via Sync IO BEFORE the future is constructed (same reasoning
    // as `test/fakes/fake_thumbnail_generator.dart`'s deliberate `*Sync`
    // calls — this file exists already, and Future.value below completes
    // via a microtask, not a real async IO wait, so no fake-async-zone hang
    // risk from `DragonArt` itself).
    final file = File('${tmp.path}/art.png')..writeAsBytesSync(_tinyPng);

    await t.pumpWidget(app(DragonArt(
      future: Future<File?>.value(file),
      size: 32,
      placeholder: const Text('placeholder'),
    )));
    await t.pump();

    expect(find.byType(Image), findsOneWidget);
    expect(find.text('placeholder'), findsNothing);
  });
}
