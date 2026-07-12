import 'package:talker_flutter/talker_flutter.dart';

/// App-wide logger. One instance, imported wherever something needs to be
/// recorded — `talker.info(...)`, `talker.warning(...)`, `talker.error(...)`,
/// `talker.handle(err, stack)`. The "Logs" button in [HomeScreen] opens a
/// [TalkerScreen] over this same instance so users can see what happened
/// without digging through console output.
final Talker talker = TalkerFlutter.init();
