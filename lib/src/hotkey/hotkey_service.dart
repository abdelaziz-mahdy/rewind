import 'package:flutter/services.dart';
import 'package:hotkey_manager/hotkey_manager.dart';

import 'hotkey_descriptor.dart';

/// Registers ONE system-wide hotkey mapped from a portable descriptor.
///
/// Thin wrapper over `hotkey_manager`; all portable parsing lives in
/// [HotkeyDescriptor]. Not unit-testable without a host window, so this
/// class is kept deliberately small and compile-checked via `flutter analyze`.
class HotkeyService {
  /// Parses [descriptor], registers it as the sole system-wide hotkey
  /// (replacing any previously bound one), and invokes [onPressed] on
  /// key-down. Returns `false` if [descriptor] is invalid, its key has no
  /// known mapping, or the OS refuses the registration (e.g. the combo is
  /// owned by another app) — in the OS-refusal case the previous hotkey is
  /// already unregistered, so the caller should surface the failure.
  Future<bool> bind(
    String descriptor,
    Future<void> Function() onPressed,
  ) async {
    final d = HotkeyDescriptor.parse(descriptor);
    if (d == null) return false;
    final key = _keys[d.key];
    if (key == null) return false;

    await hotKeyManager.unregisterAll();
    final hotKey = HotKey(
      key: key,
      modifiers: d.modifiers.map((m) => _mods[m]!).toList(),
      scope: HotKeyScope.system,
    );
    try {
      await hotKeyManager.register(hotKey, keyDownHandler: (_) => onPressed());
    } catch (_) {
      return false;
    }
    return true;
  }

  /// Unregisters the currently bound hotkey, if any.
  Future<void> dispose() => hotKeyManager.unregisterAll();

  static const _mods = {
    'alt': HotKeyModifier.alt,
    'control': HotKeyModifier.control,
    'shift': HotKeyModifier.shift,
    'meta': HotKeyModifier.meta,
  };

  static const Map<String, PhysicalKeyboardKey> _keys = {
    'f1': PhysicalKeyboardKey.f1,
    'f2': PhysicalKeyboardKey.f2,
    'f3': PhysicalKeyboardKey.f3,
    'f4': PhysicalKeyboardKey.f4,
    'f5': PhysicalKeyboardKey.f5,
    'f6': PhysicalKeyboardKey.f6,
    'f7': PhysicalKeyboardKey.f7,
    'f8': PhysicalKeyboardKey.f8,
    'f9': PhysicalKeyboardKey.f9,
    'f10': PhysicalKeyboardKey.f10,
    'f11': PhysicalKeyboardKey.f11,
    'f12': PhysicalKeyboardKey.f12,
    'a': PhysicalKeyboardKey.keyA,
    'b': PhysicalKeyboardKey.keyB,
    'c': PhysicalKeyboardKey.keyC,
    'd': PhysicalKeyboardKey.keyD,
    'e': PhysicalKeyboardKey.keyE,
    'f': PhysicalKeyboardKey.keyF,
    'g': PhysicalKeyboardKey.keyG,
    'h': PhysicalKeyboardKey.keyH,
    'i': PhysicalKeyboardKey.keyI,
    'j': PhysicalKeyboardKey.keyJ,
    'k': PhysicalKeyboardKey.keyK,
    'l': PhysicalKeyboardKey.keyL,
    'm': PhysicalKeyboardKey.keyM,
    'n': PhysicalKeyboardKey.keyN,
    'o': PhysicalKeyboardKey.keyO,
    'p': PhysicalKeyboardKey.keyP,
    'q': PhysicalKeyboardKey.keyQ,
    'r': PhysicalKeyboardKey.keyR,
    's': PhysicalKeyboardKey.keyS,
    't': PhysicalKeyboardKey.keyT,
    'u': PhysicalKeyboardKey.keyU,
    'v': PhysicalKeyboardKey.keyV,
    'w': PhysicalKeyboardKey.keyW,
    'x': PhysicalKeyboardKey.keyX,
    'y': PhysicalKeyboardKey.keyY,
    'z': PhysicalKeyboardKey.keyZ,
    '0': PhysicalKeyboardKey.digit0,
    '1': PhysicalKeyboardKey.digit1,
    '2': PhysicalKeyboardKey.digit2,
    '3': PhysicalKeyboardKey.digit3,
    '4': PhysicalKeyboardKey.digit4,
    '5': PhysicalKeyboardKey.digit5,
    '6': PhysicalKeyboardKey.digit6,
    '7': PhysicalKeyboardKey.digit7,
    '8': PhysicalKeyboardKey.digit8,
    '9': PhysicalKeyboardKey.digit9,
  };
}
