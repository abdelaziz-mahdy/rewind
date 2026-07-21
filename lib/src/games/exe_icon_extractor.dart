import 'dart:typed_data';

/// Extracts a PNG-encoded application icon embedded in a Windows PE
/// executable (`.exe`), or null when there isn't one this reader can use.
///
/// Non-Steam games run through CrossOver/Wine have no macOS bundle icon and
/// no Steam library art, so the rail would show a letter monogram. Their real
/// icon lives inside the `.exe` itself as a Windows resource — this walks the
/// PE resource tree to the best `RT_GROUP_ICON` and returns its largest
/// `RT_ICON` image WHEN that image is PNG-encoded (modern icons ship a
/// 256×256 PNG). Legacy BMP/DIB icon images are skipped (they'd need a
/// bespoke decode and a monogram is a fine fallback) — this reader never
/// throws and never returns a broken image; anything unexpected → null.
///
/// Pure Dart, no native code — reads bytes only, like a file manager showing
/// an exe's icon. Nothing is executed.
Uint8List? pngIconFromPeBytes(Uint8List bytes) {
  try {
    return _Pe(bytes).bestPngIcon();
  } catch (_) {
    return null; // Malformed/truncated PE — fall back to the monogram.
  }
}

const _rtIcon = 3;
const _rtGroupIcon = 14;
const _pngMagic = [0x89, 0x50, 0x4E, 0x47];

class _Pe {
  final Uint8List b;
  final ByteData d;

  /// File offset of the resource section's raw data, and the RVA that offset
  /// corresponds to — resource-directory internal offsets are relative to the
  /// section base, while leaf data entries carry absolute RVAs.
  late final int _resBase;
  late final List<_Section> _sections;

  _Pe(this.b) : d = ByteData.sublistView(b) {
    if (b.length < 0x40 || b[0] != 0x4D || b[1] != 0x5A) {
      throw const FormatException('not MZ');
    }
    final peOff = d.getUint32(0x3C, Endian.little);
    if (peOff + 24 > b.length ||
        b[peOff] != 0x50 ||
        b[peOff + 1] != 0x45 ||
        b[peOff + 2] != 0 ||
        b[peOff + 3] != 0) {
      throw const FormatException('no PE signature');
    }
    final numSections = d.getUint16(peOff + 6, Endian.little);
    final optSize = d.getUint16(peOff + 20, Endian.little);
    final optOff = peOff + 24;
    final magic = d.getUint16(optOff, Endian.little);
    // Data directories: 96 into the optional header for PE32, 112 for PE32+.
    final dirsOff = optOff + (magic == 0x20b ? 112 : 96);
    final resDirRva = d.getUint32(dirsOff + 2 * 8, Endian.little);

    final secTableOff = optOff + optSize;
    _sections = [
      for (var i = 0; i < numSections; i++)
        _Section.read(d, secTableOff + i * 40),
    ];

    final resSec = _sectionForRva(resDirRva);
    if (resSec == null) throw const FormatException('no resource section');
    _resBase = resSec.rawPtr + (resDirRva - resSec.virtualAddress);
  }

  _Section? _sectionForRva(int rva) {
    for (final s in _sections) {
      if (rva >= s.virtualAddress && rva < s.virtualAddress + s.virtualSize) {
        return s;
      }
    }
    return null;
  }

  int? _fileOffsetForRva(int rva) {
    final s = _sectionForRva(rva);
    if (s == null) return null;
    final off = s.rawPtr + (rva - s.virtualAddress);
    return off < b.length ? off : null;
  }

  Uint8List? bestPngIcon() {
    // Top level of the resource tree is keyed by resource TYPE.
    final groupDir = _subdirForId(_resBase, _rtGroupIcon);
    final iconDir = _subdirForId(_resBase, _rtIcon);
    if (groupDir == null || iconDir == null) return null;

    // Pick the biggest icon id across the first group's directory.
    final grp = _firstLeaf(groupDir);
    if (grp == null) return null;
    final iconId = _biggestIconId(grp);
    if (iconId == null) return null;

    // That icon id lives one level down under RT_ICON.
    final iconLeaf = _leafForId(iconDir, iconId);
    if (iconLeaf == null) return null;
    final img = _dataBytes(iconLeaf);
    if (img == null || img.length < 4) return null;
    for (var i = 0; i < 4; i++) {
      if (img[i] != _pngMagic[i]) return null; // Not PNG (BMP DIB) — skip.
    }
    return img;
  }

  /// The subdirectory offset for [id] directly under the directory at
  /// [dirOff], or null. Offsets are relative to [_resBase].
  int? _subdirForId(int dirOff, int id) {
    final entry = _entryForId(dirOff, id);
    if (entry == null) return null;
    if (!entry.isSubdir) return null;
    return _resBase + entry.offset;
  }

  /// Walks down id and language subdirectories to the first data-entry leaf.
  _DataEntry? _firstLeaf(int dirOff) {
    final e = _firstEntry(dirOff);
    if (e == null) return null;
    if (e.isSubdir) return _firstLeaf(_resBase + e.offset);
    return _readDataEntry(_resBase + e.offset);
  }

  /// The leaf under the id-keyed [dirOff] whose id == [id], descending through
  /// its language subdirectory.
  _DataEntry? _leafForId(int dirOff, int id) {
    final e = _entryForId(dirOff, id);
    if (e == null) return null;
    if (!e.isSubdir) return _readDataEntry(_resBase + e.offset);
    return _firstLeaf(_resBase + e.offset);
  }

  _DirEntry? _entryForId(int dirOff, int id) {
    final named = d.getUint16(dirOff + 12, Endian.little);
    final ids = d.getUint16(dirOff + 14, Endian.little);
    final first = dirOff + 16 + named * 8; // skip name-keyed entries
    for (var i = 0; i < ids; i++) {
      final e = _DirEntry.read(d, first + i * 8);
      if (!e.isNamed && e.id == id) return e;
    }
    return null;
  }

  _DirEntry? _firstEntry(int dirOff) {
    final named = d.getUint16(dirOff + 12, Endian.little);
    final ids = d.getUint16(dirOff + 14, Endian.little);
    if (named + ids == 0) return null;
    return _DirEntry.read(d, dirOff + 16); // first entry, named or id
  }

  _DataEntry _readDataEntry(int off) => _DataEntry(
        rva: d.getUint32(off, Endian.little),
        size: d.getUint32(off + 4, Endian.little),
      );

  Uint8List? _dataBytes(_DataEntry e) {
    final off = _fileOffsetForRva(e.rva);
    if (off == null || off + e.size > b.length) return null;
    return Uint8List.sublistView(b, off, off + e.size);
  }

  /// Reads a GRPICONDIR and returns the icon id of its largest entry.
  int? _biggestIconId(_DataEntry grp) {
    final bytes = _dataBytes(grp);
    if (bytes == null || bytes.length < 6) return null;
    final g = ByteData.sublistView(bytes);
    final count = g.getUint16(4, Endian.little);
    var bestArea = -1;
    var bestBits = -1;
    int? bestId;
    for (var i = 0; i < count; i++) {
      final o = 6 + i * 14;
      if (o + 14 > bytes.length) break;
      final w = bytes[o] == 0 ? 256 : bytes[o];
      final h = bytes[o + 1] == 0 ? 256 : bytes[o + 1];
      final bits = g.getUint16(o + 6, Endian.little);
      final id = g.getUint16(o + 12, Endian.little);
      final area = w * h;
      if (area > bestArea || (area == bestArea && bits > bestBits)) {
        bestArea = area;
        bestBits = bits;
        bestId = id;
      }
    }
    return bestId;
  }
}

class _Section {
  final int virtualSize;
  final int virtualAddress;
  final int rawPtr;
  const _Section(this.virtualSize, this.virtualAddress, this.rawPtr);

  factory _Section.read(ByteData d, int off) => _Section(
        d.getUint32(off + 8, Endian.little),
        d.getUint32(off + 12, Endian.little),
        d.getUint32(off + 20, Endian.little),
      );
}

class _DirEntry {
  final int nameOrId;
  final int offsetToData;
  const _DirEntry(this.nameOrId, this.offsetToData);

  factory _DirEntry.read(ByteData d, int off) => _DirEntry(
        d.getUint32(off, Endian.little),
        d.getUint32(off + 4, Endian.little),
      );

  bool get isNamed => (nameOrId & 0x80000000) != 0;
  int get id => nameOrId & 0x7fffffff;
  bool get isSubdir => (offsetToData & 0x80000000) != 0;
  int get offset => offsetToData & 0x7fffffff;
}

class _DataEntry {
  final int rva;
  final int size;
  const _DataEntry({required this.rva, required this.size});
}
