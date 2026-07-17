import 'dart:convert';

/// A running application with at least one capturable on-screen window, as
/// reported by `rewind_list_capturable_apps`.
class AppInfo {
  /// Stable per-app identifier (macOS bundle id, e.g. `com.apple.Safari`);
  /// pass this back to [CaptureEngine.setCaptureApp]. EMPTY for Windows
  /// programs running under CrossOver/Wine: those have no bundle id
  /// ScreenCaptureKit could match, so app capture can't target them —
  /// callers must treat "" as "capture the display instead" and never hand
  /// it to [CaptureEngine.setCaptureApp] as a real target.
  final String bundleId;

  /// Human-readable display name, for UI presentation.
  final String name;

  /// Process id at enumeration time. Not stable across relaunches — only
  /// [bundleId] should be persisted/compared.
  final int pid;

  /// Absolute path of the app bundle's `.icns` icon, when the bundle
  /// declares one. Null for Wine apps (no bundle), asset-catalog-only apps,
  /// and older enumerations; the file may also simply not exist — callers
  /// must fall back to a placeholder (see `GameTileAvatar`) either way.
  final String? iconPath;

  /// CGWindowID of the app's frontmost window at enumeration time (0 if
  /// unknown). As ephemeral as [pid] — never persist it. The capture target
  /// for Wine apps: pass to [CaptureEngine.setCaptureWindow], since an
  /// empty [bundleId] gives [CaptureEngine.setCaptureApp] nothing to match.
  final int windowId;

  /// Whether this app's emitted window is currently visible on a display
  /// (`kCGWindowIsOnscreen`). Since enumeration spans ALL Spaces (so the
  /// picker can list a fullscreen game on its own Space), this is how the
  /// "follow the game" auto-switch tells the VISIBLE match from a hidden one:
  /// native League runs its client/lobby AND the match as separate windows
  /// both named "League of Legends", and only the on-screen one is the game
  /// being played. Defaults to true when absent (older shim, tests) so
  /// callers that don't care see no behaviour change.
  final bool onScreen;

  const AppInfo({
    required this.bundleId,
    required this.name,
    required this.pid,
    this.iconPath,
    this.windowId = 0,
    this.onScreen = true,
  });

  factory AppInfo.fromJson(Map<String, dynamic> j) {
    final icon = j['icon'] as String?;
    return AppInfo(
      bundleId: j['bundle_id'] as String,
      name: j['name'] as String,
      pid: j['pid'] as int,
      iconPath: (icon == null || icon.isEmpty) ? null : icon,
      windowId: j['window_id'] as int? ?? 0,
      onScreen: j['on_screen'] as bool? ?? true,
    );
  }

  /// Parses the compact JSON array emitted by `rewind_list_capturable_apps`.
  static List<AppInfo> listFromJson(String json) => (jsonDecode(json) as List)
      .map((e) => AppInfo.fromJson((e as Map).cast<String, dynamic>()))
      .toList();

  @override
  String toString() => 'AppInfo($bundleId, $name, pid=$pid)';
}
