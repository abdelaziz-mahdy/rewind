import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
import 'app_settings.dart';

/// Loads/saves [AppSettings] as JSON in an injected directory
/// (production: <application support>/settings.json; tests: a temp dir).
class SettingsStore {
  final Directory dir;
  SettingsStore(this.dir);

  File get file => File(p.join(dir.path, 'settings.json'));

  Future<AppSettings> load() async {
    if (!await file.exists()) return AppSettings();
    try {
      final j = jsonDecode(await file.readAsString());
      return AppSettings.fromJson((j as Map).cast<String, dynamic>());
    } catch (_) {
      // Never crash on a corrupt file: keep it for inspection, start fresh.
      try {
        await file.rename('${file.path}.bad');
      } catch (_) {}
      return AppSettings();
    }
  }

  /// The tail of the write queue — see [save].
  Future<void> _lastWrite = Future.value();

  /// Persists [settings]. Writes are SERIALIZED: every save shares the one
  /// `settings.json.tmp` scratch path, so two unserialized concurrent
  /// saves race — writer B truncates the tmp file mid-A-write, then A's
  /// rename publishes B's half-written JSON as the settings file (whose
  /// corruption [load] then "recovers" from by resetting to defaults —
  /// silent total settings loss). Each write therefore chains after the
  /// previous one has fully renamed.
  ///
  /// The JSON is snapshotted HERE, not when the queued write runs, so an
  /// awaited save persists the state as of the call; a save that enqueues
  /// behind a slow disk still writes what its caller saw. Last write in
  /// the queue wins the file, which is the right semantics for a
  /// mutate-in-place settings object.
  Future<void> save(AppSettings settings) {
    final jsonText =
        const JsonEncoder.withIndent('  ').convert(settings.toJson());
    final write = _lastWrite.then((_) => _writeSnapshot(jsonText));
    // A failed write (disk full, permissions) must not jam the queue
    // forever — the NEXT save should still try. The caller's own returned
    // future still surfaces the error.
    _lastWrite = write.then((_) {}, onError: (_) {});
    return write;
  }

  Future<void> _writeSnapshot(String jsonText) async {
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(jsonText);
    await tmp.rename(file.path); // atomic-ish replace
  }
}
