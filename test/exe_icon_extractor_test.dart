import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/games/exe_icon_extractor.dart';

/// A real, decodable 1×1 PNG — the icon image the fixture embeds.
final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVR42mNk+A8A'
    'AQUBAScY42YAAAAASUVORK5CYII=');

/// Builds a minimal-but-valid PE whose resource tree holds one RT_GROUP_ICON
/// pointing at one RT_ICON containing [iconBytes]. Offsets are hand-laid so
/// the resource section's RVA equals its file offset (0x100), keeping the
/// RVA→file mapping trivial. Mirrors the layout `pngIconFromPeBytes` walks.
Uint8List _fakePe(List<int> iconBytes) {
  final b = Uint8List(0x400);
  final d = ByteData.sublistView(b);
  void u16(int off, int v) => d.setUint16(off, v, Endian.little);
  void u32(int off, int v) => d.setUint32(off, v, Endian.little);

  b[0] = 0x4D; // 'M'
  b[1] = 0x5A; // 'Z'
  u32(0x3C, 0x40); // e_lfanew -> PE header
  b[0x40] = 0x50; // 'P'
  b[0x41] = 0x45; // 'E'
  u16(0x46, 1); // numberOfSections
  u16(0x54, 120); // sizeOfOptionalHeader
  u16(0x58, 0x10b); // optional magic = PE32
  u32(0xC8, 0x100); // data dir[2] (resource) RVA
  u32(0xCC, 0x300); // data dir[2] size

  // Section header (.rsrc) at optOff(0x58)+optSize(120)=0xD0.
  const rsrc = [0x2E, 0x72, 0x73, 0x72, 0x63]; // ".rsrc"
  for (var i = 0; i < rsrc.length; i++) {
    b[0xD0 + i] = rsrc[i];
  }
  u32(0xD8, 0x300); // virtualSize
  u32(0xDC, 0x100); // virtualAddress
  u32(0xE0, 0x300); // sizeOfRawData
  u32(0xE4, 0x100); // pointerToRawData

  const base = 0x100;
  const sub = 0x80000000; // subdirectory flag

  // TYPE directory (2 id entries: RT_ICON=3, RT_GROUP_ICON=14).
  u16(base + 14, 2);
  u32(base + 16, 3);
  u32(base + 20, sub | 0x20);
  u32(base + 24, 14);
  u32(base + 28, sub | 0x50);

  // RT_ICON id directory -> id 1 -> lang subdir.
  u16(base + 0x20 + 14, 1);
  u32(base + 0x30, 1);
  u32(base + 0x34, sub | 0x38);
  // RT_ICON lang directory -> data entry at base+0x80.
  u16(base + 0x38 + 14, 1);
  u32(base + 0x48, 0x409);
  u32(base + 0x4C, 0x80);

  // RT_GROUP_ICON id directory -> id 1 -> lang subdir.
  u16(base + 0x50 + 14, 1);
  u32(base + 0x60, 1);
  u32(base + 0x64, sub | 0x68);
  // lang directory -> data entry at base+0x90.
  u16(base + 0x68 + 14, 1);
  u32(base + 0x78, 0x409);
  u32(base + 0x7C, 0x90);

  // Data entry (icon image) at base+0x80: RVA 0x1C0.
  u32(base + 0x80, 0x1C0);
  u32(base + 0x84, iconBytes.length);
  // Data entry (group dir) at base+0x90: RVA 0x1A0, size 20.
  u32(base + 0x90, 0x1A0);
  u32(base + 0x94, 20);

  // GRPICONDIR at base+0xA0: 1 entry, 256×256, 32bpp, iconId 1.
  u16(base + 0xA0 + 2, 1); // type = icon
  u16(base + 0xA0 + 4, 1); // count
  // entry (14 bytes): width/height 0 => 256, planes 1, bits 32, iconId 1
  u16(base + 0xA0 + 6 + 4, 1); // planes
  u16(base + 0xA0 + 6 + 6, 32); // bitCount
  u32(base + 0xA0 + 6 + 8, iconBytes.length); // bytesInRes
  u16(base + 0xA0 + 6 + 12, 1); // iconId

  // Icon image bytes at base+0xC0 (RVA 0x1C0).
  for (var i = 0; i < iconBytes.length; i++) {
    b[base + 0xC0 + i] = iconBytes[i];
  }
  return b;
}

void main() {
  test('extracts the embedded PNG icon from a PE exe', () {
    final out = pngIconFromPeBytes(_fakePe(_png));
    expect(out, isNotNull);
    expect(out, equals(_png));
  });

  test('returns null for a non-PNG (BMP DIB) icon image', () {
    // A BITMAPINFOHEADER-shaped blob (starts 0x28 00 00 00), not PNG.
    final dib = <int>[0x28, 0, 0, 0, ...List.filled(60, 0)];
    expect(pngIconFromPeBytes(_fakePe(dib)), isNull);
  });

  test('returns null for non-PE bytes', () {
    expect(pngIconFromPeBytes(Uint8List.fromList(utf8.encode('not an exe'))),
        isNull);
    expect(pngIconFromPeBytes(Uint8List(0)), isNull);
  });

  test('returns null for a PE with no resource section', () {
    final pe = _fakePe(_png);
    // Corrupt the resource data-directory RVA so no section contains it.
    ByteData.sublistView(pe).setUint32(0xC8, 0x99999, Endian.little);
    expect(pngIconFromPeBytes(pe), isNull);
  });
}
