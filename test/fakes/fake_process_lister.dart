import 'package:rewind/src/events/process_watcher_source.dart';

/// A controllable [ProcessLister] for driving [ProcessWatcherSource] in
/// tests without shelling out to `ps`/`tasklist`. Set [names] to simulate
/// the running process list a supervision tick would see.
class FakeProcessLister implements ProcessLister {
  List<String> names = const [];

  @override
  Future<List<String>> runningProcessNames() async => names;
}
