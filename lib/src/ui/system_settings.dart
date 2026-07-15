import 'dart:io';

/// The project's GitHub repo (badges/links). Update if the repo moves.
const String kRepoUrl = 'https://github.com/abdelaziz-mahdy/rewind';

/// Opens a URL in the default browser (best-effort, no extra dependency —
/// `open` on macOS, `explorer`/`start` on Windows).
Future<void> openUrl(String url) async {
  try {
    if (Platform.isMacOS) {
      await Process.run('open', [url]);
    } else if (Platform.isWindows) {
      await Process.run('cmd', ['/c', 'start', '', url]);
    }
  } catch (_) {
    // Best-effort.
  }
}

/// Opens macOS System Settings straight to Privacy → Screen Recording, where
/// the user grants Rewind capture access. Best-effort: an unsupported
/// platform or missing handler is not fatal. Shared by the capture-error
/// banner and the onboarding flow.
Future<void> openScreenRecordingSettings() async {
  if (!Platform.isMacOS) return;
  try {
    await Process.run('open', [
      'x-apple.systempreferences:com.apple.preference.security'
          '?Privacy_ScreenCapture'
    ]);
  } catch (_) {
    // Best-effort: no OS handler available is not fatal.
  }
}
