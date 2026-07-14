/// Minimal Apple Icon Image (`.icns`) reader: extracts the best PNG-encoded
/// entry so Flutter's `Image.memory` can render a real app icon without any
/// native image framework. Modern icns entries (10.7+) are plain PNG bytes
/// inside a chunked container; legacy RLE/JPEG2000 entries are skipped —
/// callers fall back to a placeholder when null is returned.
///
/// Container layout: 8-byte header (`icns` magic + big-endian total size),
/// then chunks of 4-byte type + 4-byte big-endian length (length INCLUDES
/// the 8-byte chunk header) + payload.
library;

import 'dart:io';
import 'dart:typed_data';

/// Chunk types that hold whole-icon bitmaps, in preference order for a
/// ~20-40 px menu row: smallest sharp sizes first, giant ones last (they
/// decode slower and downscale no better).
const _preferredTypes = [
  'icp5', // 32
  'ic11', // 16@2x (32 px)
  'icp6', // 64
  'ic12', // 32@2x (64 px)
  'ic07', // 128
  'ic13', // 128@2x (256 px)
  'ic08', // 256
  'ic14', // 256@2x (512 px)
  'ic09', // 512
  'ic10', // 512@2x (1024 px)
  'icp4', // 16
  'ic04', // 16 (ARGB or PNG)
  'ic05', // 32 (ARGB or PNG)
];

const _pngMagic = [0x89, 0x50, 0x4E, 0x47];

bool _isPng(Uint8List data, int offset) {
  if (offset + 4 > data.length) return false;
  for (var i = 0; i < 4; i++) {
    if (data[offset + i] != _pngMagic[i]) return false;
  }
  return true;
}

/// Extracts the preferred PNG entry from raw `.icns` bytes, or null when the
/// container is malformed or holds no PNG-encoded entries.
Uint8List? pngFromIcnsBytes(Uint8List bytes) {
  if (bytes.length < 8) return null;
  if (String.fromCharCodes(bytes, 0, 4) != 'icns') return null;
  final data = ByteData.sublistView(bytes);

  final found = <String, Uint8List>{};
  var offset = 8;
  while (offset + 8 <= bytes.length) {
    final type = String.fromCharCodes(bytes, offset, offset + 4);
    final length = data.getUint32(offset + 4);
    if (length < 8 || offset + length > bytes.length) break;
    if (_preferredTypes.contains(type) &&
        !found.containsKey(type) &&
        _isPng(bytes, offset + 8)) {
      found[type] = Uint8List.sublistView(bytes, offset + 8, offset + length);
    }
    offset += length;
  }

  for (final type in _preferredTypes) {
    final png = found[type];
    if (png != null) return png;
  }
  return null;
}

/// Per-path memo for [loadAppIconPng] — icon files don't change while the
/// app runs, and menu opens must not re-read multi-megabyte .icns files.
/// Failed lookups are cached too (null), so a missing icon costs one stat.
final Map<String, Uint8List?> _cache = {};

/// Visible for tests.
void clearAppIconCache() => _cache.clear();

/// PNG bytes for the app icon at [iconPath] (an `.icns` file), or null when
/// the file is missing/unreadable/has no PNG entry. Synchronous by design:
/// it's called from popup-menu row builders; the memo keeps repeat opens
/// free.
Uint8List? loadAppIconPng(String iconPath) {
  return _cache.putIfAbsent(iconPath, () {
    try {
      final f = File(iconPath);
      if (!f.existsSync()) return null;
      return pngFromIcnsBytes(f.readAsBytesSync());
    } catch (_) {
      return null;
    }
  });
}
