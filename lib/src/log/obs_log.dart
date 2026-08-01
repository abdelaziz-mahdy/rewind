import '../obs/capture_engine.dart';
import 'log.dart';

/// Moves libobs' own log lines onto the app's logger (and so into the Logs
/// screen and the session log file).
///
/// libobs explains itself: a module that would not load, an encoder that
/// would not start, a capture stream the OS tore down. Its default handler
/// writes to stderr, which a bundled `.app` discards — so an app-side log
/// could report "buffer not running" while the reason was thrown away. This
/// is the other half of that message.
///
/// Pull, not push: the shim's handler runs on whatever thread libobs logged
/// from (encoder, graphics, the ScreenCaptureKit callback), so it parks lines
/// in a ring for someone to collect rather than calling into Dart from a
/// foreign thread. Called on the perf monitor's existing tick — the app's one
/// always-on timer, so this adds none — and again the moment a capture
/// operation fails, so the explaining lines sit next to the failure in the
/// log instead of up to a tick later.
void forwardObsLog(CaptureEngine? engine) {
  if (engine == null) return;
  for (final line in engine.drainObsLog()) {
    final message = 'libobs: ${line.message}';
    // libobs levels: 100 error, 200 warning, 300 info. The shim drops 400
    // (debug) before it ever reaches the ring.
    if (line.level <= 100) {
      talker.error(message);
    } else if (line.level <= 200) {
      talker.warning(message);
    } else {
      talker.info(message);
    }
  }
}
