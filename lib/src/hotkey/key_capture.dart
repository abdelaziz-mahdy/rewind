import 'package:flutter/services.dart';

import 'hotkey_descriptor.dart';

/// Outcome of mapping one hardware key-down event during hotkey recording.
enum HotkeyCaptureStatus {
  /// [HotkeyCapture.descriptor] is a valid combo — recording is done.
  accepted,

  /// A letter/digit key was pressed with no modifier held. Rejected because
  /// a bare key (e.g. plain "S") would be a hostile global hotkey — it
  /// would fire while the user is just typing. Recording should stay open
  /// so the user can add a modifier and try again.
  rejectedNoModifier,

  /// Not a terminal key for a hotkey: a pure modifier key (Alt/Ctrl/Shift/
  /// Meta on its own, still being held) or a physical key the descriptor
  /// grammar doesn't support. Recording should stay open.
  ignored,
}

/// Result of [mapKeyDownToHotkey]: either an accepted [descriptor], or a
/// [status] explaining why nothing was captured yet.
class HotkeyCapture {
  final HotkeyCaptureStatus status;
  final HotkeyDescriptor? descriptor;

  const HotkeyCapture._(this.status, this.descriptor);

  const HotkeyCapture.accepted(HotkeyDescriptor descriptor)
      : this._(HotkeyCaptureStatus.accepted, descriptor);

  const HotkeyCapture.rejectedNoModifier()
      : this._(HotkeyCaptureStatus.rejectedNoModifier, null);

  const HotkeyCapture.ignored() : this._(HotkeyCaptureStatus.ignored, null);
}

/// Maps a raw key-down [event] plus the currently-held modifier flags to a
/// [HotkeyCapture]. Physical-key based (not logical/character based) so the
/// captured combo matches what [HotkeyService] can actually bind, and so
/// recording is layout-independent — consistent with the physical-key map
/// `HotkeyService` already uses to register the hotkey with the OS.
HotkeyCapture mapKeyDownToHotkey(
  KeyDownEvent event, {
  required bool alt,
  required bool control,
  required bool shift,
  required bool meta,
}) {
  final mods = <String>[
    if (alt) 'alt',
    if (control) 'control',
    if (meta) 'meta',
    if (shift) 'shift',
  ]..sort();

  final fKey = _fKeysByPhysical[event.physicalKey];
  if (fKey != null) {
    return HotkeyCapture.accepted(HotkeyDescriptor(mods, fKey));
  }

  final letterOrDigit = _lettersDigitsByPhysical[event.physicalKey];
  if (letterOrDigit != null) {
    if (mods.isEmpty) return const HotkeyCapture.rejectedNoModifier();
    return HotkeyCapture.accepted(HotkeyDescriptor(mods, letterOrDigit));
  }

  return const HotkeyCapture.ignored();
}

final _fKeysByPhysical = {
  PhysicalKeyboardKey.f1: 'f1',
  PhysicalKeyboardKey.f2: 'f2',
  PhysicalKeyboardKey.f3: 'f3',
  PhysicalKeyboardKey.f4: 'f4',
  PhysicalKeyboardKey.f5: 'f5',
  PhysicalKeyboardKey.f6: 'f6',
  PhysicalKeyboardKey.f7: 'f7',
  PhysicalKeyboardKey.f8: 'f8',
  PhysicalKeyboardKey.f9: 'f9',
  PhysicalKeyboardKey.f10: 'f10',
  PhysicalKeyboardKey.f11: 'f11',
  PhysicalKeyboardKey.f12: 'f12',
};

final _lettersDigitsByPhysical = {
  PhysicalKeyboardKey.keyA: 'a',
  PhysicalKeyboardKey.keyB: 'b',
  PhysicalKeyboardKey.keyC: 'c',
  PhysicalKeyboardKey.keyD: 'd',
  PhysicalKeyboardKey.keyE: 'e',
  PhysicalKeyboardKey.keyF: 'f',
  PhysicalKeyboardKey.keyG: 'g',
  PhysicalKeyboardKey.keyH: 'h',
  PhysicalKeyboardKey.keyI: 'i',
  PhysicalKeyboardKey.keyJ: 'j',
  PhysicalKeyboardKey.keyK: 'k',
  PhysicalKeyboardKey.keyL: 'l',
  PhysicalKeyboardKey.keyM: 'm',
  PhysicalKeyboardKey.keyN: 'n',
  PhysicalKeyboardKey.keyO: 'o',
  PhysicalKeyboardKey.keyP: 'p',
  PhysicalKeyboardKey.keyQ: 'q',
  PhysicalKeyboardKey.keyR: 'r',
  PhysicalKeyboardKey.keyS: 's',
  PhysicalKeyboardKey.keyT: 't',
  PhysicalKeyboardKey.keyU: 'u',
  PhysicalKeyboardKey.keyV: 'v',
  PhysicalKeyboardKey.keyW: 'w',
  PhysicalKeyboardKey.keyX: 'x',
  PhysicalKeyboardKey.keyY: 'y',
  PhysicalKeyboardKey.keyZ: 'z',
  PhysicalKeyboardKey.digit0: '0',
  PhysicalKeyboardKey.digit1: '1',
  PhysicalKeyboardKey.digit2: '2',
  PhysicalKeyboardKey.digit3: '3',
  PhysicalKeyboardKey.digit4: '4',
  PhysicalKeyboardKey.digit5: '5',
  PhysicalKeyboardKey.digit6: '6',
  PhysicalKeyboardKey.digit7: '7',
  PhysicalKeyboardKey.digit8: '8',
  PhysicalKeyboardKey.digit9: '9',
};
