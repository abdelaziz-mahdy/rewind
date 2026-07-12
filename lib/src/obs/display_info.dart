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
