import 'dart:io';

/// The project's GitHub repo (badges/links). Update if the repo moves.
const String kRepoUrl = 'https://github.com/abdelaziz-mahdy/rewind';

/// Riot's Developer API Policy requires this boilerplate, VERBATIM, "in a
/// location that is readily visible to players" for any product that uses
/// their APIs or game-specific static data — Rewind reads the League Live
/// Client Data API and renders Data Dragon champion/item art, so it applies.
/// Shown in Settings → About & help. Do not reword, shorten, or hide it.
/// See docs/COMPLIANCE.md.
const String kRiotDisclaimer =
    'Rewind is not endorsed by Riot Games and does not reflect the views or '
    'opinions of Riot Games or anyone officially involved in producing or '
    'managing Riot Games properties. Riot Games and all associated properties '
    'are trademarks or registered trademarks of Riot Games, Inc.';

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
