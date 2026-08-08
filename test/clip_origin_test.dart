import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/clip/clip.dart';
import 'package:rewind/src/events/game_event.dart';

/// `Clip.origin` decides what counts as source footage for an export, so it
/// has to be right for clips written before the field existed too.
void main() {
  Map<String, dynamic> stored({
    String? origin,
    String? eventLabel,
    String path = '/clips/rewind-1.mp4',
  }) =>
      {
        'path': path,
        'gameId': 'app:game',
        'event': GameEventKind.manual.name,
        'createdAt': DateTime(2026, 8, 8).toIso8601String(),
        'sizeBytes': 1,
        if (origin != null) 'origin': origin,
        if (eventLabel != null) 'eventLabel': eventLabel,
      };

  test('a stored origin is used as-is', () {
    expect(
        Clip.fromJson(stored(origin: 'exported')).origin, ClipOrigin.exported);
    expect(Clip.fromJson(stored(origin: 'trimmed')).origin, ClipOrigin.trimmed);
  });

  test('legacy clips fall back to the label the derived paths wrote', () {
    expect(Clip.fromJson(stored(eventLabel: 'Full match')).origin,
        ClipOrigin.exported);
    expect(Clip.fromJson(stored(eventLabel: 'Trimmed')).origin,
        ClipOrigin.trimmed);
  });

  // An achievement's real name lives in the same field, so a label alone
  // can never mean "derived".
  test('an achievement name is not a derived marker', () {
    expect(Clip.fromJson(stored(eventLabel: 'Big Pack')).origin,
        ClipOrigin.captured);
  });

  // An export written before any marker existed was adopted by the library's
  // stray-file scan as a plain clip — 764 MB of it, sitting in a session
  // ready to be swallowed by the next export.
  test('an unlabelled export is recognised by its file name', () {
    expect(
      Clip.fromJson(stored(path: '/clips/rewind-1-full-match.mp4')).origin,
      ClipOrigin.exported,
    );
    expect(
      Clip.fromJson(stored(path: '/clips/rewind-1-trim-2.mp4')).origin,
      ClipOrigin.trimmed,
    );
    expect(Clip.fromJson(stored()).origin, ClipOrigin.captured);
  });
}
