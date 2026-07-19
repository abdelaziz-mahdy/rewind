import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/events/steam_stats_vdf.dart';

/// A minimal binary-VDF WRITER, the mirror image of the parser under test --
/// used only to build synthetic fixtures matching the brief's documented
/// hexdump shape. Never used against, or built from, a real Steam file (see
/// steam_stats_vdf.dart's doc).
class _VdfBuilder {
  final BytesBuilder _b = BytesBuilder();

  void _key(String key) {
    _b.add(utf8.encode(key));
    _b.addByte(0);
  }

  void nestedStart(String key) {
    _b.addByte(0x00);
    _key(key);
  }

  void end() => _b.addByte(0x08);

  void stringEntry(String key, String value) {
    _b.addByte(0x01);
    _key(key);
    _b.add(utf8.encode(value));
    _b.addByte(0);
  }

  void int32Entry(String key, int value) {
    _b.addByte(0x02);
    _key(key);
    final bd = ByteData(4)..setInt32(0, value, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  void uint64Entry(String key, int value) {
    _b.addByte(0x07);
    _key(key);
    final bd = ByteData(8)..setUint64(0, value, Endian.little);
    _b.add(bd.buffer.asUint8List());
  }

  Uint8List build() => _b.toBytes();
}

/// Matches the brief's documented hexdump structure: root `cache` -> `crc`
/// -> `PendingChanges` -> `data` -> `AchievementTimes` -> {index: epoch}.
Uint8List _statsFixture(Map<int, int> achievementTimes, {int crc = 12345}) {
  final b = _VdfBuilder()
    ..nestedStart('cache')
    ..uint64Entry('crc', crc)
    ..nestedStart('PendingChanges')
    ..nestedStart('data')
    ..nestedStart('AchievementTimes');
  for (final entry in achievementTimes.entries) {
    b.int32Entry('${entry.key}', entry.value);
  }
  b
    ..end() // AchievementTimes
    ..end() // data
    ..end() // PendingChanges
    ..end(); // cache
  return b.build();
}

/// A schema fixture with one `type 4` (achievements) stats group holding a
/// `bits` block -- the well-known public shape of Steam's schema binary VDF
/// (see steam_stats_vdf.dart's doc for the caveat that this is inferred, not
/// verified against a real file).
Uint8List _schemaFixture(Map<int, ({String apiName, String? english})> bits) {
  final b = _VdfBuilder()
    ..nestedStart('1234560')
    ..nestedStart('stats')
    ..nestedStart('0')
    ..int32Entry('type', 4)
    ..nestedStart('bits');
  for (final entry in bits.entries) {
    final bit = entry.value;
    b.nestedStart('${entry.key}');
    b.stringEntry('name', bit.apiName);
    if (bit.english != null) {
      b
        ..nestedStart('display')
        ..nestedStart('name')
        ..stringEntry('english', bit.english!)
        ..end() // name
        ..end(); // display
    }
    b.end(); // this bit
  }
  b
    ..end() // bits
    ..end() // stats group "0"
    ..end() // stats
    ..end(); // root appid
  return b.build();
}

void main() {
  group('parseAchievementUnlockTimes', () {
    test(
        'extracts index -> unlock time from the documented cache/'
        'PendingChanges/data/AchievementTimes shape', () {
      final bytes = _statsFixture({17: 1700000000, 19: 1700000500});
      final result = parseAchievementUnlockTimes(bytes);
      expect(result, isNotNull);
      expect(result!.keys, containsAll([17, 19]));
      expect(result[17],
          DateTime.fromMillisecondsSinceEpoch(1700000000 * 1000, isUtc: true));
      expect(result[19],
          DateTime.fromMillisecondsSinceEpoch(1700000500 * 1000, isUtc: true));
    });

    test(
        'an empty AchievementTimes block parses to an empty map (a '
        'freshly-seeded game with nothing unlocked yet is normal, not a '
        'failure)', () {
      final bytes = _statsFixture(const {});
      expect(parseAchievementUnlockTimes(bytes), isEmpty);
    });

    test(
        'well-formed bytes with no AchievementTimes block anywhere: empty '
        'map, not null', () {
      final b = _VdfBuilder()
        ..nestedStart('cache')
        ..uint64Entry('crc', 1)
        ..end();
      expect(parseAchievementUnlockTimes(b.build()), isEmpty);
    });

    test('completely empty bytes: empty map, not null', () {
      expect(parseAchievementUnlockTimes(Uint8List(0)), isEmpty);
    });

    test('truncated mid-write file fails CLOSED (null), never throws', () {
      final bytes = _statsFixture({17: 1700000000});
      for (final cut in [1, bytes.length ~/ 2, bytes.length - 1]) {
        final truncated = Uint8List.sublistView(bytes, 0, cut);
        expect(parseAchievementUnlockTimes(truncated), isNull,
            reason: 'truncated at $cut bytes');
      }
    });

    test('garbage bytes fail CLOSED (null), never throw', () {
      final garbage =
          Uint8List.fromList(List.generate(64, (i) => (i * 37) % 256));
      expect(parseAchievementUnlockTimes(garbage), isNull);
    });

    test(
        'a non-numeric index key inside AchievementTimes is skipped, not '
        'fatal', () {
      final b = _VdfBuilder()
        ..nestedStart('cache')
        ..nestedStart('PendingChanges')
        ..nestedStart('data')
        ..nestedStart('AchievementTimes')
        ..int32Entry('17', 1700000000)
        ..stringEntry('notAnIndex', 'garbage')
        ..end()
        ..end()
        ..end()
        ..end();
      final result = parseAchievementUnlockTimes(b.build());
      expect(result, isNotNull);
      expect(result!.keys, [17]);
    });

    test('a non-integer value for an index is skipped, not fatal', () {
      final b = _VdfBuilder()
        ..nestedStart('cache')
        ..nestedStart('PendingChanges')
        ..nestedStart('data')
        ..nestedStart('AchievementTimes')
        ..int32Entry('17', 1700000000)
        ..stringEntry('19', 'not a timestamp')
        ..end()
        ..end()
        ..end()
        ..end();
      final result = parseAchievementUnlockTimes(b.build());
      expect(result, isNotNull);
      expect(result!.keys, [17]);
    });
  });

  group('parseAchievementDisplayNames', () {
    test('extracts index -> english display name from a `bits` block', () {
      final bytes = _schemaFixture({
        17: (apiName: 'ACH_WIN', english: 'Winner Winner'),
        19: (apiName: 'ACH_LOSE', english: 'Better Luck Next Time'),
      });
      final result = parseAchievementDisplayNames(bytes);
      expect(result[17], 'Winner Winner');
      expect(result[19], 'Better Luck Next Time');
    });

    test(
        'falls back to the raw api name when no display/name/english is '
        'present', () {
      final bytes = _schemaFixture({
        17: (apiName: 'ACH_RAW', english: null),
      });
      expect(parseAchievementDisplayNames(bytes)[17], 'ACH_RAW');
    });

    test('malformed/garbage bytes: empty map, never throws', () {
      final garbage = Uint8List.fromList(List.generate(40, (i) => 255 - i));
      expect(parseAchievementDisplayNames(garbage), isEmpty);
    });

    test('truncated schema bytes: empty map, never throws', () {
      final bytes = _schemaFixture({17: (apiName: 'A', english: 'A name')});
      final truncated = Uint8List.sublistView(bytes, 0, bytes.length - 3);
      expect(parseAchievementDisplayNames(truncated), isEmpty);
    });

    test('no bits block anywhere: empty map', () {
      final b = _VdfBuilder()
        ..nestedStart('1234560')
        ..stringEntry('name', 'Some Game')
        ..end();
      expect(parseAchievementDisplayNames(b.build()), isEmpty);
    });
  });
}
