import 'dart:collection';
import 'dart:convert';
import 'dart:typed_data';

/// Tolerant parsing of Valve's BINARY KeyValues ("binary VDF") format, as
/// used by Steam's local stats cache -- `appcache/stats/UserGameStats_
/// <accountId3>_<appid>.bin` and its sibling `UserGameStatsSchema_<appid>
/// .bin` (see `SteamStatsWatcher`'s doc for how these two files are used
/// together, and docs/COMPLIANCE.md for why reading them is in-bounds).
///
/// This is a small, generic tree parser -- it makes NO assumption about
/// which keys exist at which depth beyond the type-tag grammar itself, so a
/// Steam client version that reorders/renames sibling keys (anything short
/// of changing the wire format) doesn't break it. The two extraction
/// functions below then SCAN the parsed tree for the specific blocks they
/// need ([parseAchievementUnlockTimes] for `AchievementTimes`,
/// [parseAchievementDisplayNames] for `bits`) rather than assuming an exact
/// path -- the brief's "scan for the block" tolerance.
///
/// Every entry point here is a pure function over bytes: no file IO, no
/// globals besides the type-tag constants. Hermetically tested against
/// synthetic fixtures built with matching helpers in the test file -- NEVER
/// against a real user file (Steam's format is undocumented; nothing here
/// is derived from copied parser code, see docs/COMPLIANCE.md).

/// One value in a parsed binary-VDF tree. A closed hierarchy (not
/// extensible outside this file) so extraction code can exhaustively
/// pattern-match without a default case swallowing a future addition.
sealed class VdfValue {
  const VdfValue();
}

/// An object/nested block -- Valve's type 0x00. Its children retain
/// insertion (file) order, which [parseAchievementDisplayNames] relies on
/// when walking `bits` blocks.
class VdfNested extends VdfValue {
  final Map<String, VdfValue> children;
  const VdfNested(this.children);
}

/// Any of Valve's integer-shaped types (int32, uint64, int64, color,
/// pointer) collapsed to one Dart `int` -- callers here only ever need the
/// numeric value, never which wire type produced it.
class VdfInt extends VdfValue {
  final int value;
  const VdfInt(this.value);
}

class VdfString extends VdfValue {
  final String value;
  const VdfString(this.value);
}

class VdfFloat extends VdfValue {
  final double value;
  const VdfFloat(this.value);
}

const _typeNested = 0x00;
const _typeString = 0x01;
const _typeInt32 = 0x02;
const _typeFloat32 = 0x03;
const _typePointer = 0x04;
const _typeWString = 0x05;
const _typeColor = 0x06;
const _typeUint64 = 0x07;
const _typeEnd = 0x08;
const _typeInt64A = 0x0A;
const _typeInt64B = 0x0B;

/// How many nested levels [_readValue] will recurse before giving up
/// (fail-closed) -- guards against a maliciously/corruptly deep object graph
/// blowing the call stack. Real Steam schema/stats files nest at most a
/// handful of levels deep (see this file's doc for the documented shape).
const _maxDepth = 64;

class _ByteReader {
  final Uint8List bytes;
  int offset = 0;
  _ByteReader(this.bytes);

  late final ByteData _data = ByteData.sublistView(bytes);

  bool get atEnd => offset >= bytes.length;

  int _advance(int n) {
    if (offset + n > bytes.length) {
      throw const FormatException('truncated binary VDF');
    }
    final at = offset;
    offset += n;
    return at;
  }

  int readByte() => bytes[_advance(1)];

  String readCString() {
    final start = offset;
    while (true) {
      if (offset >= bytes.length) {
        throw const FormatException('unterminated string in binary VDF');
      }
      if (bytes[offset] == 0) break;
      offset++;
    }
    final s = utf8.decode(bytes.sublist(start, offset), allowMalformed: true);
    offset++; // consume the null terminator
    return s;
  }

  int readInt32() => _data.getInt32(_advance(4), Endian.little);
  int readUint32() => _data.getUint32(_advance(4), Endian.little);
  double readFloat32() => _data.getFloat32(_advance(4), Endian.little);
  int readInt64() => _data.getInt64(_advance(8), Endian.little);
  int readUint64() => _data.getUint64(_advance(8), Endian.little);

  /// A UTF-16LE, double-null-terminated string -- Valve's rarely-used
  /// WString type. Steam's stats/schema files never actually carry one in
  /// practice, but a type byte this parser doesn't know how to SKIP would
  /// desync every sibling/parent read after it, so it's still handled.
  String readWString() {
    final units = <int>[];
    while (true) {
      final unit = _data.getUint16(_advance(2), Endian.little);
      if (unit == 0) break;
      units.add(unit);
    }
    return String.fromCharCodes(units);
  }
}

/// Parses the top level of a binary-VDF byte stream into its entries,
/// tolerating -- via a top-level try/catch -- any malformed or truncated
/// input by returning null rather than throwing. Never null on well-formed
/// input, including an EMPTY well-formed stream (yields `{}`).
Map<String, VdfValue>? parseBinaryVdfRoot(Uint8List bytes) {
  try {
    final reader = _ByteReader(bytes);
    final root = <String, VdfValue>{};
    while (!reader.atEnd) {
      final type = reader.readByte();
      if (type == _typeEnd) break; // tolerate a stray end marker at top level
      final key = reader.readCString();
      root[key] = _readValue(reader, type, _maxDepth);
    }
    return root;
  } catch (_) {
    return null;
  }
}

VdfValue _readValue(_ByteReader r, int type, int depthBudget) {
  switch (type) {
    case _typeNested:
      if (depthBudget <= 0) {
        throw const FormatException('binary VDF nested too deep');
      }
      final children = <String, VdfValue>{};
      while (true) {
        final t = r.readByte();
        if (t == _typeEnd) break;
        final key = r.readCString();
        children[key] = _readValue(r, t, depthBudget - 1);
      }
      return VdfNested(children);
    case _typeString:
      return VdfString(r.readCString());
    case _typeInt32:
      return VdfInt(r.readInt32());
    case _typeFloat32:
      return VdfFloat(r.readFloat32());
    case _typePointer:
      return VdfInt(r.readUint32());
    case _typeWString:
      return VdfString(r.readWString());
    case _typeColor:
      return VdfInt(r.readUint32());
    case _typeUint64:
      return VdfInt(r.readUint64());
    case _typeInt64A:
    case _typeInt64B:
      return VdfInt(r.readInt64());
    default:
      throw FormatException(
          'unknown binary VDF type 0x${type.toRadixString(16)}');
  }
}

/// Breadth-first search for the first [VdfNested] found anywhere in the tree
/// under key [key], at any depth -- the "scan for the block" tolerance this
/// file's doc describes, rather than assuming an exact path.
VdfNested? _findFirstNested(Map<String, VdfValue> root, String key) {
  final queue = Queue<Map<String, VdfValue>>()..add(root);
  while (queue.isNotEmpty) {
    final level = queue.removeFirst();
    final direct = level[key];
    if (direct is VdfNested) return direct;
    for (final value in level.values) {
      if (value is VdfNested) queue.add(value.children);
    }
  }
  return null;
}

/// Every [VdfNested] found anywhere in the tree under key [key], in
/// breadth-first document order -- used by [parseAchievementDisplayNames] to
/// find every `bits` block regardless of how many stats groups the schema
/// has.
List<VdfNested> _findAllNested(Map<String, VdfValue> root, String key) {
  final found = <VdfNested>[];
  final queue = Queue<Map<String, VdfValue>>()..add(root);
  while (queue.isNotEmpty) {
    final level = queue.removeFirst();
    for (final entry in level.entries) {
      final value = entry.value;
      if (value is VdfNested) {
        if (entry.key == key) found.add(value);
        queue.add(value.children);
      }
    }
  }
  return found;
}

/// Extracts the `AchievementTimes` block from a `UserGameStats_<id3>_
/// <appid>.bin` file's bytes: achievement index -> unlock time (UTC).
///
/// Fails CLOSED (returns null) on anything that doesn't parse as binary VDF
/// at all -- a truncated file mid-write, or genuinely unexpected content.
/// Returns an EMPTY map (not null) when the bytes parse fine but no
/// `AchievementTimes` block is found, or it has no entries -- both are
/// normal (a freshly-seeded game with nothing unlocked yet), not failures.
/// A malformed individual entry (a non-numeric key, or a value that isn't
/// an integer) is skipped rather than aborting the whole block.
Map<int, DateTime>? parseAchievementUnlockTimes(Uint8List bytes) {
  final root = parseBinaryVdfRoot(bytes);
  if (root == null) return null;
  final block = _findFirstNested(root, 'AchievementTimes');
  if (block == null) return const {};

  final result = <int, DateTime>{};
  for (final entry in block.children.entries) {
    final index = int.tryParse(entry.key);
    if (index == null) continue;
    final value = entry.value;
    if (value is! VdfInt) continue;
    result[index] =
        DateTime.fromMillisecondsSinceEpoch(value.value * 1000, isUtc: true);
  }
  return result;
}

/// Extracts achievement index -> display name from a `UserGameStatsSchema_
/// <appid>.bin` file's bytes, for [SteamStatsWatcher]'s fallback-friendly
/// display-name lookup.
///
/// ASSUMPTION (undocumented format, no verified real file available -- see
/// this file's doc): a schema's achievement bit index (its key within a
/// `bits` block) is the SAME identifier space as `AchievementTimes`' index
/// key in the stats file, i.e. both count the same underlying per-game
/// boolean achievement vector. If a Steam client version breaks that
/// assumption, this simply returns the wrong (or no) name for an index --
/// never wrong DATA, since [SteamStatsWatcher] always has a numbered
/// fallback ("Achievement #<index>") when a lookup misses.
///
/// Best-effort only: never throws, returns an empty map on anything
/// unparseable -- a schema-file problem must never withhold the achievement
/// clip itself (see `SteamStatsWatcher._displayNameFor`), only its nicest
/// label.
Map<int, String> parseAchievementDisplayNames(Uint8List bytes) {
  try {
    final root = parseBinaryVdfRoot(bytes);
    if (root == null) return const {};
    final names = <int, String>{};
    for (final bits in _findAllNested(root, 'bits')) {
      for (final entry in bits.children.entries) {
        final index = int.tryParse(entry.key);
        if (index == null) continue;
        final achievement = entry.value;
        if (achievement is! VdfNested) continue;
        final name = _englishDisplayName(achievement) ?? _apiName(achievement);
        if (name != null) names[index] = name;
      }
    }
    return names;
  } catch (_) {
    return const {};
  }
}

String? _englishDisplayName(VdfNested achievement) {
  final display = achievement.children['display'];
  if (display is! VdfNested) return null;
  final name = display.children['name'];
  if (name is! VdfNested) return null;
  final english = name.children['english'];
  return english is VdfString ? english.value : null;
}

String? _apiName(VdfNested achievement) {
  final name = achievement.children['name'];
  return name is VdfString ? name.value : null;
}
