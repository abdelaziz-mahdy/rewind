import 'dart:convert';

/// A connected display, as reported by `rewind_list_displays`.
class DisplayInfo {
  /// Stable per-display identifier (`CGDisplayCreateUUIDFromDisplayID` on
  /// macOS); pass this back to [CaptureEngine.setCaptureDisplay].
  final String uuid;

  /// Display resolution in points, as libobs reports it.
  final int width;
  final int height;

  /// Whether this is the OS's current main/primary display.
  final bool isMain;

  const DisplayInfo({
    required this.uuid,
    required this.width,
    required this.height,
    required this.isMain,
  });

  factory DisplayInfo.fromJson(Map<String, dynamic> j) => DisplayInfo(
        uuid: j['uuid'] as String,
        width: j['width'] as int,
        height: j['height'] as int,
        isMain: j['main'] as bool? ?? false,
      );

  /// Parses the compact JSON array emitted by `rewind_list_displays`.
  static List<DisplayInfo> listFromJson(String json) =>
      (jsonDecode(json) as List)
          .map((e) => DisplayInfo.fromJson((e as Map).cast<String, dynamic>()))
          .toList();

  @override
  String toString() => 'DisplayInfo($uuid, ${width}x$height'
      '${isMain ? ', main' : ''})';
}

/// The saved capture-display UUID to actually apply, or null for "use the
/// main display".
///
/// A stale UUID (e.g. an unplugged external monitor) must not be applied, or
/// capture silently records black — BUT only a NON-EMPTY [displays] list that
/// lacks [saved] proves the display is gone. An EMPTY list means enumeration
/// itself failed (a display asleep/clamshell, the screen locked, or a
/// fullscreen game holding its own Space at launch) — not that the monitor
/// disappeared. Wiping the choice then would silently fall capture back to the
/// MAIN display and record the WRONG monitor; the shim resolves the UUID
/// itself (see `rewind_obs_macos.c` `display_uuid`), so an empty list keeps
/// [saved]. Only "enumerated, and it's genuinely missing" returns null.
String? validDisplayUuid(String? saved, List<DisplayInfo> displays) {
  if (saved == null) return null;
  if (displays.isEmpty) return saved;
  return displays.any((d) => d.uuid == saved) ? saved : null;
}
