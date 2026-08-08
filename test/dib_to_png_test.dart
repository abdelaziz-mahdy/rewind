import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/dib_to_png.dart';

/// Builds a BITMAPINFOHEADER icon DIB: [w]x[h] pixels at [bitCount] bpp,
/// followed by its 1bpp AND mask, the way an `RT_ICON` resource stores one.
Uint8List dib({
  required int w,
  required int h,
  required int bitCount,
  List<int> palette = const [],
  required List<int> pixels,
  List<int>? andMask,
  int compression = 0,
}) {
  final header = ByteData(40)
    ..setUint32(0, 40, Endian.little)
    ..setInt32(4, w, Endian.little)
    // Doubled: the colour image and the AND mask are stacked.
    ..setInt32(8, h * 2, Endian.little)
    ..setUint16(12, 1, Endian.little)
    ..setUint16(14, bitCount, Endian.little)
    ..setUint32(16, compression, Endian.little)
    ..setUint32(32, palette.length ~/ 4, Endian.little);

  int stride(int bits) => ((w * bits + 31) ~/ 32) * 4;
  final mask = andMask ?? List.filled(stride(1) * h, 0);
  return Uint8List.fromList([
    ...header.buffer.asUint8List(),
    ...palette,
    ...pixels,
    ...mask,
  ]);
}

/// PNG's IHDR carries the dimensions at a fixed offset — enough to prove the
/// geometry survived without decoding the image.
({int width, int height}) pngSize(Uint8List png) {
  final d = ByteData.sublistView(png);
  return (width: d.getUint32(16), height: d.getUint32(20));
}

void main() {
  test('a 32bpp BGRA icon converts, keeping its dimensions', () {
    // 2x2, every pixel opaque blue.
    final pixels = <int>[];
    for (var i = 0; i < 4; i++) {
      pixels.addAll([0xFF, 0x00, 0x00, 0xFF]); // B G R A
    }
    final png = dibIconToPng(dib(w: 2, h: 2, bitCount: 32, pixels: pixels));

    expect(png, isNotNull);
    expect(png!.sublist(0, 4), [0x89, 0x50, 0x4E, 0x47]);
    expect(pngSize(png), (width: 2, height: 2));
  });

  // Old encoders wrote 32bpp icons with an all-zero alpha channel and left
  // transparency to the AND mask. Taken at face value the icon is invisible,
  // which reads as a rendering bug rather than a missing icon.
  test('a 32bpp icon with no alpha at all falls back to the AND mask', () {
    final pixels = <int>[];
    for (var i = 0; i < 4; i++) {
      pixels.addAll([0xFF, 0x00, 0x00, 0x00]); // alpha 0 everywhere
    }
    // AND mask: one 4-byte-aligned row per line, all bits clear = opaque.
    final png = dibIconToPng(dib(
      w: 2,
      h: 2,
      bitCount: 32,
      pixels: pixels,
      andMask: List.filled(8, 0),
    ));

    expect(png, isNotNull);
    expect(pngSize(png!), (width: 2, height: 2));
  });

  test('a 24bpp icon converts', () {
    // 2x2 at 3 bytes/px, padded to a 4-byte stride (8 bytes per row).
    final row = <int>[0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00];
    final png =
        dibIconToPng(dib(w: 2, h: 2, bitCount: 24, pixels: [...row, ...row]));

    expect(png, isNotNull);
    expect(pngSize(png!), (width: 2, height: 2));
  });

  test('an 8bpp palettised icon converts', () {
    final palette = <int>[];
    for (var i = 0; i < 256; i++) {
      palette.addAll([i, i, i, 0]); // B G R reserved
    }
    // 2x2 at 1 byte/px, padded to a 4-byte stride.
    final png = dibIconToPng(dib(
      w: 2,
      h: 2,
      bitCount: 8,
      palette: palette,
      pixels: [1, 2, 0, 0, 3, 4, 0, 0],
    ));

    expect(png, isNotNull);
    expect(pngSize(png!), (width: 2, height: 2));
  });

  group('refuses rather than returning something broken', () {
    test('a compressed DIB', () {
      final pixels = List.filled(16, 0);
      expect(
        dibIconToPng(
            dib(w: 2, h: 2, bitCount: 32, pixels: pixels, compression: 1)),
        isNull,
      );
    });

    test('a bit depth Windows icons never use', () {
      expect(
        dibIconToPng(dib(w: 2, h: 2, bitCount: 16, pixels: List.filled(16, 0))),
        isNull,
      );
    });

    test('a truncated pixel array', () {
      final full = dib(w: 8, h: 8, bitCount: 32, pixels: List.filled(256, 0));
      expect(dibIconToPng(full.sublist(0, 60)), isNull);
    });

    test('bytes that are not a DIB at all', () {
      expect(dibIconToPng(Uint8List.fromList([1, 2, 3])), isNull);
      expect(dibIconToPng(Uint8List(0)), isNull);
    });

    // Guards against a malformed header claiming a huge canvas and having us
    // allocate it before noticing.
    test('dimensions far too large to be an icon', () {
      final header = ByteData(40)
        ..setUint32(0, 40, Endian.little)
        ..setInt32(4, 100000, Endian.little)
        ..setInt32(8, 100000, Endian.little)
        ..setUint16(14, 32, Endian.little);
      expect(dibIconToPng(header.buffer.asUint8List()), isNull);
    });
  });
}
