import 'dart:io';

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
