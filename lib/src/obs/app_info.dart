import 'dart:convert';

/// A running application with at least one capturable on-screen window, as
/// reported by `rewind_list_capturable_apps`.
class AppInfo {
  /// Stable per-app identifier (macOS bundle id, e.g. `com.apple.Safari`);
  /// pass this back to [CaptureEngine.setCaptureApp].
  final String bundleId;

  /// Human-readable display name, for UI presentation.
  final String name;

  /// Process id at enumeration time. Not stable across relaunches — only
  /// [bundleId] should be persisted/compared.
  final int pid;

  const AppInfo({
    required this.bundleId,
    required this.name,
    required this.pid,
  });

  factory AppInfo.fromJson(Map<String, dynamic> j) => AppInfo(
        bundleId: j['bundle_id'] as String,
        name: j['name'] as String,
        pid: j['pid'] as int,
      );

  /// Parses the compact JSON array emitted by `rewind_list_capturable_apps`.
  static List<AppInfo> listFromJson(String json) => (jsonDecode(json) as List)
      .map((e) => AppInfo.fromJson((e as Map).cast<String, dynamic>()))
      .toList();

  @override
  String toString() => 'AppInfo($bundleId, $name, pid=$pid)';
}
