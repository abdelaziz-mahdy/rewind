import 'dart:io';

import 'package:integration_test/integration_test_driver_extended.dart';

/// Driver for the UI-tour integration test — writes each screenshot the
/// test requests to `screenshots/<name>.png` at the repo root. Run with:
///
///   flutter drive \
///     --driver=test_driver/integration_test.dart \
///     --target=integration_test/ui_tour_test.dart -d macos
Future<void> main() => integrationDriver(
      onScreenshot: (String name, List<int> bytes,
          [Map<String, Object?>? _]) async {
        final file = File('screenshots/$name.png');
        await file.parent.create(recursive: true);
        await file.writeAsBytes(bytes);
        return true;
      },
    );
