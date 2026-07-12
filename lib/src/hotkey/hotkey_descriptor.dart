/// Portable "Alt+F10"-style hotkey descriptor, independent of any plugin.
class HotkeyDescriptor {
  final List<String> modifiers; // canonical, sorted: alt control meta shift
  final String key; // canonical lowercase: f1..f12, a..z, 0..9

  const HotkeyDescriptor(this.modifiers, this.key);

  static const _aliases = {
    'alt': 'alt',
    'option': 'alt',
    'ctrl': 'control',
    'control': 'control',
    'shift': 'shift',
    'meta': 'meta',
    'cmd': 'meta',
    'command': 'meta',
    'win': 'meta',
  };

  static final _keyPattern = RegExp(r'^(f([1-9]|1[0-2])|[a-z]|[0-9])$');

  static HotkeyDescriptor? parse(String descriptor) {
    final parts = descriptor
        .split('+')
        .map((s) => s.trim().toLowerCase())
        .where((s) => s.isNotEmpty)
        .toList();
    if (parts.isEmpty) return null;
    final key = parts.removeLast();
    if (!_keyPattern.hasMatch(key)) return null;
    final mods = <String>{};
    for (final m in parts) {
      final canonical = _aliases[m];
      if (canonical == null) return null;
      mods.add(canonical);
    }
    return HotkeyDescriptor(mods.toList()..sort(), key);
  }

  @override
  String toString() {
    String cap(String s) => s[0].toUpperCase() + s.substring(1);
    final mods =
        modifiers.map((m) => {'control': 'Ctrl'}[m] ?? cap(m)).join('+');
    final k = key.toUpperCase();
    return mods.isEmpty ? k : '$mods+$k';
  }
}
