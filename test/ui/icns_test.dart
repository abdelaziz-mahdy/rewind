import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/ui/icns.dart';

/// A tiny valid PNG (1×1 transparent pixel) — enough for magic-byte checks;
/// pngFromIcnsBytes never decodes pixels.
final _tinyPng = Uint8List.fromList([
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, // PNG signature
  0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, // IHDR
  0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1F, 0x15, 0xC4, 0x89,
  0, 0, 0, 0, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82, // IEND
]);

/// Builds an icns container from (type, payload) chunks.
Uint8List _icns(List<(String, List<int>)> chunks) {
  final body = <int>[];
  for (final (type, payload) in chunks) {
    body.addAll(type.codeUnits);
    final len = payload.length + 8;
    body.addAll(
        [len >> 24 & 0xFF, len >> 16 & 0xFF, len >> 8 & 0xFF, len & 0xFF]);
    body.addAll(payload);
  }
  final total = body.length + 8;
  return Uint8List.fromList([
    ...'icns'.codeUnits,
    total >> 24 & 0xFF,
    total >> 16 & 0xFF,
    total >> 8 & 0xFF,
    total & 0xFF,
    ...body,
  ]);
}

void main() {
  group('pngFromIcnsBytes', () {
    test('extracts a PNG-encoded entry', () {
      final png = pngFromIcnsBytes(_icns([('icp5', _tinyPng)]));
      expect(png, isNotNull);
      expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    });

    test('prefers small sharp sizes over giant ones', () {
      // ic10 is 1024px; icp5 is 32px — the menu wants the small one.
      final big = Uint8List.fromList([..._tinyPng, 0xAA]);
      final png = pngFromIcnsBytes(_icns([('ic10', big), ('icp5', _tinyPng)]));
      expect(png, hasLength(_tinyPng.length));
    });

    test('skips non-PNG (legacy RLE/JP2) entries', () {
      final rle = List<int>.filled(32, 0x42); // not PNG magic
      expect(pngFromIcnsBytes(_icns([('icp5', rle)])), isNull);
    });

    test('rejects a non-icns container', () {
      expect(pngFromIcnsBytes(Uint8List.fromList('PK...garbage'.codeUnits)),
          isNull);
      expect(pngFromIcnsBytes(Uint8List(0)), isNull);
    });

    test('tolerates a truncated chunk length without throwing', () {
      final bytes = _icns([('icp5', _tinyPng)]);
      expect(pngFromIcnsBytes(bytes.sublist(0, bytes.length - 10)), isNull);
    });
  });

  group('loadAppIconPng', () {
    setUp(clearAppIconCache);

    test('missing file resolves (and caches) as null', () {
      expect(loadAppIconPng('/nonexistent/App.icns'), isNull);
      expect(loadAppIconPng('/nonexistent/App.icns'), isNull);
    });
  });
}
