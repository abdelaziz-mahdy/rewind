import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/hotkey/hotkey_descriptor.dart';

void main() {
  test('parses Alt+F10', () {
    final d = HotkeyDescriptor.parse('Alt+F10')!;
    expect(d.modifiers, ['alt']);
    expect(d.key, 'f10');
  });
  test('parses Ctrl+Shift+S with canonical order and aliases', () {
    final d = HotkeyDescriptor.parse('Shift+CTRL+s')!;
    expect(d.modifiers, ['control', 'shift']); // sorted canonical
    expect(d.key, 's');
  });
  test('cmd is an alias for meta', () {
    expect(HotkeyDescriptor.parse('Cmd+K')!.modifiers, ['meta']);
  });
  test('rejects empty, modifier-only, unknown key', () {
    expect(HotkeyDescriptor.parse(''), isNull);
    expect(HotkeyDescriptor.parse('Alt+'), isNull);
    expect(HotkeyDescriptor.parse('Alt+Banana'), isNull);
  });
  test('round-trips toString', () {
    expect(HotkeyDescriptor.parse('Alt+F10').toString(), 'Alt+F10');
  });
}
