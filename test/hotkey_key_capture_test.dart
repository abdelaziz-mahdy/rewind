import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:rewind/src/hotkey/key_capture.dart';

/// Builds a synthetic key-down event for a given physical/logical key pair,
/// the same shape the recorder field receives from `Focus.onKeyEvent`.
KeyDownEvent _down(PhysicalKeyboardKey physical, LogicalKeyboardKey logical) =>
    KeyDownEvent(
      physicalKey: physical,
      logicalKey: logical,
      timeStamp: Duration.zero,
    );

void main() {
  test('F-key with a modifier is accepted', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.f10, LogicalKeyboardKey.f10),
      alt: true,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.accepted);
    expect(capture.descriptor.toString(), 'Alt+F10');
  });

  test('bare F-key with no modifier is accepted', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.f9, LogicalKeyboardKey.f9),
      alt: false,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.accepted);
    expect(capture.descriptor.toString(), 'F9');
  });

  test('bare letter with no modifier is rejected', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.keyS, LogicalKeyboardKey.keyS),
      alt: false,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.rejectedNoModifier);
    expect(capture.descriptor, isNull);
  });

  test('bare digit with no modifier is rejected', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.digit5, LogicalKeyboardKey.digit5),
      alt: false,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.rejectedNoModifier);
  });

  test('letter with a modifier is accepted, modifiers canonically sorted', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.keyK, LogicalKeyboardKey.keyK),
      alt: false,
      control: true,
      shift: true,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.accepted);
    expect(capture.descriptor.toString(), 'Ctrl+Shift+K');
  });

  test('a pure-modifier physical key (still holding Alt) is ignored', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.altLeft, LogicalKeyboardKey.altLeft),
      alt: true,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.ignored);
    expect(capture.descriptor, isNull);
  });

  test('an unsupported key (e.g. Enter) is ignored', () {
    final capture = mapKeyDownToHotkey(
      _down(PhysicalKeyboardKey.enter, LogicalKeyboardKey.enter),
      alt: false,
      control: false,
      shift: false,
      meta: false,
    );
    expect(capture.status, HotkeyCaptureStatus.ignored);
  });
}
