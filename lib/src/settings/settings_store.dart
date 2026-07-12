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

  Future<void> save(AppSettings settings) async {
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsString(
        const JsonEncoder.withIndent('  ').convert(settings.toJson()));
    await tmp.rename(file.path); // atomic-ish replace
  }
}
