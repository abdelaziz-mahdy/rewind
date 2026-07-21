import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:rewind/src/games/exe_icon_resolver.dart';
import 'package:rewind/src/obs/app_info.dart';

final _png = base64Decode(
    'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAAAAAA6fptVAAAAC0lEQVR42mNk+A8A'
    'AQUBAScY42YAAAAASUVORK5CYII=');

/// Same minimal PE fixture as exe_icon_extractor_test, embedding [icon].
Uint8List _fakePe(List<int> icon) {
  final b = Uint8List(0x400);
  final d = ByteData.sublistView(b);
  void u16(int o, int v) => d.setUint16(o, v, Endian.little);
  void u32(int o, int v) => d.setUint32(o, v, Endian.little);
  b[0] = 0x4D;
  b[1] = 0x5A;
  u32(0x3C, 0x40);
  b[0x40] = 0x50;
  b[0x41] = 0x45;
  u16(0x46, 1);
  u16(0x54, 120);
  u16(0x58, 0x10b);
  u32(0xC8, 0x100);
  u32(0xCC, 0x300);
  for (final (i, c) in [0x2E, 0x72, 0x73, 0x72, 0x63].indexed) {
    b[0xD0 + i] = c;
  }
  u32(0xD8, 0x300);
  u32(0xDC, 0x100);
  u32(0xE0, 0x300);
  u32(0xE4, 0x100);
  const base = 0x100;
  const sub = 0x80000000;
  u16(base + 14, 2);
  u32(base + 16, 3);
  u32(base + 20, sub | 0x20);
  u32(base + 24, 14);
  u32(base + 28, sub | 0x50);
  u16(base + 0x20 + 14, 1);
  u32(base + 0x30, 1);
  u32(base + 0x34, sub | 0x38);
  u16(base + 0x38 + 14, 1);
  u32(base + 0x48, 0x409);
  u32(base + 0x4C, 0x80);
  u16(base + 0x50 + 14, 1);
  u32(base + 0x60, 1);
  u32(base + 0x64, sub | 0x68);
  u16(base + 0x68 + 14, 1);
  u32(base + 0x78, 0x409);
  u32(base + 0x7C, 0x90);
  u32(base + 0x80, 0x1C0);
  u32(base + 0x84, icon.length);
  u32(base + 0x90, 0x1A0);
  u32(base + 0x94, 20);
  u16(base + 0xA0 + 2, 1);
  u16(base + 0xA0 + 4, 1);
  u16(base + 0xA0 + 6 + 4, 1);
  u16(base + 0xA0 + 6 + 6, 32);
  u32(base + 0xA0 + 6 + 8, icon.length);
  u16(base + 0xA0 + 6 + 12, 1);
  for (var i = 0; i < icon.length; i++) {
    b[base + 0xC0 + i] = icon[i];
  }
  return b;
}

void main() {
  late Directory tmp;
  late Directory driveC;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('exeicon');
    driveC = Directory(p.join(tmp.path, 'bottle', 'drive_c'))
      ..createSync(recursive: true);
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  ExeIconResolver resolver({required Future<String?> Function(int) pid}) =>
      ExeIconResolver(
        cacheDir: Directory(p.join(tmp.path, 'icons')),
        bottleDriveCs: () => [driveC],
        exePathForPid: pid,
      );

  AppInfo wineApp(String name, int pid) =>
      AppInfo(bundleId: '', name: name, pid: pid);

  test('resolves a Wine game icon from its exe inside the bottle', () async {
    final gameDir = Directory(p.join(driveC.path, 'Program Files', 'Cool'))
      ..createSync(recursive: true);
    File(p.join(gameDir.path, 'Cool.exe')).writeAsBytesSync(_fakePe(_png));

    final r = resolver(pid: (_) async => r'C:\Program Files\Cool\Cool.exe');
    final path = await r.iconForApp(wineApp('Cool', 1));

    expect(path, isNotNull);
    expect(File(path!).existsSync(), isTrue);
    expect(File(path).readAsBytesSync(), equals(_png));
  });

  test('returns null when the exe cannot be found in any bottle', () async {
    final r = resolver(pid: (_) async => r'C:\Nope\Missing.exe');
    expect(await r.iconForApp(wineApp('Missing', 2)), isNull);
  });

  test('returns null for a normal macOS app (has a bundle id)', () async {
    var called = false;
    final r = ExeIconResolver(
      cacheDir: Directory(p.join(tmp.path, 'icons')),
      bottleDriveCs: () => [driveC],
      exePathForPid: (_) async {
        called = true;
        return null;
      },
    );
    final path = await r
        .iconForApp(const AppInfo(bundleId: 'com.x.y', name: 'Y', pid: 3));
    expect(path, isNull);
    expect(called, isFalse); // short-circuits before touching the process list
  });

  test('returns null when the exe has no PNG icon', () async {
    final gameDir = Directory(p.join(driveC.path, 'NoIcon'))
      ..createSync(recursive: true);
    File(p.join(gameDir.path, 'NoIcon.exe'))
        .writeAsBytesSync(_fakePe(const [0x28, 0, 0, 0, 0, 0, 0, 0]));

    final r = resolver(pid: (_) async => r'C:\NoIcon\NoIcon.exe');
    expect(await r.iconForApp(wineApp('NoIcon', 4)), isNull);
  });

  test('memoizes: the exe is resolved once per app name', () async {
    final gameDir = Directory(p.join(driveC.path, 'M'))
      ..createSync(recursive: true);
    File(p.join(gameDir.path, 'M.exe')).writeAsBytesSync(_fakePe(_png));

    var lookups = 0;
    final r = resolver(pid: (_) async {
      lookups++;
      return r'C:\M\M.exe';
    });
    final a = await r.iconForApp(wineApp('M', 5));
    final b = await r.iconForApp(wineApp('M', 5));
    expect(a, b);
    expect(lookups, 1);
  });
}
