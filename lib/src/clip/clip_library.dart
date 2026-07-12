import 'clip.dart';

/// In-memory index of clips. TODO(v0.3): persist to a JSON/SQLite store and
/// hydrate from the clips directory on startup.
class ClipLibrary {
  final List<Clip> _clips = [];

  List<Clip> get all => List.unmodifiable(_clips);

  void add(Clip clip) => _clips.add(clip);

  void remove(Clip clip) => _clips.remove(clip);

  void setProtected(Clip clip, bool value) => clip.protected = value;

  int get totalBytes => _clips.fold(0, (sum, c) => sum + c.sizeBytes);
}
