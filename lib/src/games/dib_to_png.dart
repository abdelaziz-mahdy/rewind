import 'dart:io';
import 'dart:typed_data';

/// Converts a Windows icon image stored as a DIB (BITMAPINFOHEADER + pixels,
/// the classic `RT_ICON` payload) into a PNG.
///
/// Windows icons come in two flavours inside an `.exe`: a PNG blob (what
/// modern 256×256 icons ship) or a raw DIB (everything else, including most
/// game icons). Reading only the PNG kind meant a game whose icon happens to
/// be stored the old way was indistinguishable from a game with no icon at
/// all — a letter monogram either way. Measured on this machine, that was the
/// common case, not the exotic one: of four real Wine executables, exactly one
/// had a PNG icon.
///
/// Supports the bit depths Windows icons actually use: 32bpp BGRA, 24bpp BGR,
/// and 8/4/1bpp palettised. Anything else — or a compressed DIB, which icons
/// do not use — returns null, and the caller keeps its monogram.
///
/// Never throws: a malformed or truncated image is null, not an exception.
Uint8List? dibIconToPng(Uint8List dib) {
  try {
    return _convert(dib);
  } catch (_) {
    return null;
  }
}

Uint8List? _convert(Uint8List dib) {
  if (dib.length < 40) return null;
  final d = ByteData.sublistView(dib);

  final headerSize = d.getUint32(0, Endian.little);
  if (headerSize < 40 || headerSize > dib.length) return null;
  final width = d.getInt32(4, Endian.little);
  // An icon DIB stores the colour image and its 1bpp AND mask stacked, so
  // the declared height is TWICE the real one.
  final storedHeight = d.getInt32(8, Endian.little);
  final bitCount = d.getUint16(14, Endian.little);
  final compression = d.getUint32(16, Endian.little);
  var paletteCount = d.getUint32(32, Endian.little);

  if (compression != 0) return null; // BI_RGB only; icons are never compressed
  if (width <= 0 || storedHeight <= 0) return null;
  if (width > 1024 || storedHeight > 2048) return null; // not an icon
  final height = storedHeight ~/ 2;
  if (height == 0) return null;

  if (paletteCount == 0 && bitCount <= 8) paletteCount = 1 << bitCount;
  final paletteBytes = paletteCount * 4;
  final pixelStart = headerSize + paletteBytes;
  if (pixelStart > dib.length) return null;

  // Rows are bottom-up and padded to a 4-byte boundary.
  int stride(int bits) => ((width * bits + 31) ~/ 32) * 4;
  final xorStride = stride(bitCount);
  final andStride = stride(1);
  final xorSize = xorStride * height;
  if (pixelStart + xorSize > dib.length) return null;

  final andStart = pixelStart + xorSize;
  final hasAndMask = andStart + andStride * height <= dib.length;

  int alphaFromMask(int x, int y) {
    if (!hasAndMask) return 255;
    final row = height - 1 - y;
    final byte = dib[andStart + row * andStride + (x >> 3)];
    // A set AND-mask bit means "transparent".
    return (byte >> (7 - (x & 7))) & 1 == 1 ? 0 : 255;
  }

  final rgba = Uint8List(width * height * 4);
  var sawAlpha = false;

  for (var y = 0; y < height; y++) {
    final row = height - 1 - y; // bottom-up
    final rowStart = pixelStart + row * xorStride;
    for (var x = 0; x < width; x++) {
      int r, g, b, a;
      switch (bitCount) {
        case 32:
          final i = rowStart + x * 4;
          b = dib[i];
          g = dib[i + 1];
          r = dib[i + 2];
          a = dib[i + 3];
          if (a != 0) sawAlpha = true;
        case 24:
          final i = rowStart + x * 3;
          b = dib[i];
          g = dib[i + 1];
          r = dib[i + 2];
          a = alphaFromMask(x, y);
        case 8 || 4 || 1:
          final int index;
          if (bitCount == 8) {
            index = dib[rowStart + x];
          } else {
            final perByte = 8 ~/ bitCount;
            final byte = dib[rowStart + x ~/ perByte];
            final shift = 8 - bitCount * (x % perByte + 1);
            index = (byte >> shift) & ((1 << bitCount) - 1);
          }
          final p = headerSize + index * 4;
          if (p + 2 >= dib.length) return null;
          b = dib[p];
          g = dib[p + 1];
          r = dib[p + 2];
          a = alphaFromMask(x, y);
        default:
          return null;
      }
      final o = (y * width + x) * 4;
      rgba[o] = r;
      rgba[o + 1] = g;
      rgba[o + 2] = b;
      rgba[o + 3] = a;
    }
  }

  // A 32bpp icon with an all-zero alpha channel is fully transparent as
  // written — old encoders left it that way and relied on the AND mask.
  // Taking it at face value would produce an invisible icon, which reads as
  // a rendering bug rather than a missing one.
  if (bitCount == 32 && !sawAlpha) {
    for (var y = 0; y < height; y++) {
      for (var x = 0; x < width; x++) {
        rgba[(y * width + x) * 4 + 3] = alphaFromMask(x, y);
      }
    }
  }

  return _encodePng(rgba, width, height);
}

/// Minimal PNG encoder: 8-bit RGBA, one IDAT, no interlacing.
///
/// Hand-rolled rather than pulled from a package: this is the only image
/// encoding in the app, and a PNG with fixed colour type is a header, one
/// zlib stream (dart:io already has the codec) and three CRCs.
Uint8List _encodePng(Uint8List rgba, int width, int height) {
  // Each scanline is prefixed with its filter type; 0 = none, which costs a
  // little size and no complexity. The zlib codec does the actual work.
  final raw = Uint8List((width * 4 + 1) * height);
  var o = 0;
  for (var y = 0; y < height; y++) {
    raw[o++] = 0;
    raw.setRange(o, o + width * 4, rgba, y * width * 4);
    o += width * 4;
  }

  final out = BytesBuilder();
  out.add(const [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

  final ihdr = BytesBuilder()
    ..add(_u32(width))
    ..add(_u32(height))
    ..add(
        const [8, 6, 0, 0, 0]); // 8-bit, RGBA, deflate, no filter, no interlace
  out.add(_chunk('IHDR', ihdr.takeBytes()));
  out.add(_chunk('IDAT', Uint8List.fromList(ZLibCodec(level: 6).encode(raw))));
  out.add(_chunk('IEND', Uint8List(0)));
  return out.takeBytes();
}

Uint8List _u32(int v) => Uint8List(4)
  ..[0] = (v >> 24) & 0xFF
  ..[1] = (v >> 16) & 0xFF
  ..[2] = (v >> 8) & 0xFF
  ..[3] = v & 0xFF;

Uint8List _chunk(String type, Uint8List data) {
  final typeBytes = Uint8List.fromList(type.codeUnits);
  final body = Uint8List(typeBytes.length + data.length)
    ..setRange(0, typeBytes.length, typeBytes)
    ..setRange(typeBytes.length, typeBytes.length + data.length, data);
  return Uint8List.fromList([
    ..._u32(data.length),
    ...body,
    ..._u32(_crc32(body)),
  ]);
}

final _crcTable = List<int>.generate(256, (n) {
  var c = n;
  for (var k = 0; k < 8; k++) {
    c = (c & 1) == 1 ? 0xEDB88320 ^ (c >> 1) : c >> 1;
  }
  return c;
});

int _crc32(Uint8List bytes) {
  var c = 0xFFFFFFFF;
  for (final b in bytes) {
    c = _crcTable[(c ^ b) & 0xFF] ^ (c >> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}
