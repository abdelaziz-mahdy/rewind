import 'dart:io' show Platform;

import 'package:tray_manager/tray_manager.dart';

/// Menu-bar / system-tray presence with quick actions.
///
/// `tray_manager`'s Windows backend loads the tray icon via
/// `LoadImage(..., IMAGE_ICON, ..., LR_LOADFROMFILE)`, which needs a real
/// `.ico` (a PNG loads as null → blank tray icon). macOS instead wants a
/// template PNG (`isTemplate: true` lets the OS tint it for light/dark menu
/// bars). Each platform therefore gets its own asset.
class TrayService with TrayListener {
  Future<void> Function()? _onSaveClip;
  Future<void> Function(bool)? _onToggleBuffer;
  Future<void> Function()? _onToggleRecording;
  void Function()? _onShowWindow;
  void Function()? _onQuit;
  Future<void> Function()? _onOpenClips;
  bool _bufferActive = true;
  bool _recording = false;

  Future<void> init({
    required Future<void> Function() onSaveClip,
    required Future<void> Function(bool startNotStop) onToggleBuffer,
    required Future<void> Function() onToggleRecording,
    required void Function() onShowWindow,
    required void Function() onQuit,
    required Future<void> Function() onOpenClips,
  }) async {
    _onSaveClip = onSaveClip;
    _onToggleBuffer = onToggleBuffer;
    _onToggleRecording = onToggleRecording;
    _onShowWindow = onShowWindow;
    _onQuit = onQuit;
    _onOpenClips = onOpenClips;
    // Re-init must not stack duplicate listeners (each would re-fire every
    // menu callback); ObserverList.add permits duplicates.
    trayManager.removeListener(this);
    trayManager.addListener(this);
    await trayManager.setIcon(
      Platform.isWindows
          ? 'assets/tray/tray_icon_windows.ico'
          : 'assets/tray/tray_icon.png',
      isTemplate: !Platform.isWindows,
    );
    await _rebuildMenu();
  }

  Future<void> setBufferState(bool active) async {
    _bufferActive = active;
    await _rebuildMenu();
    await _syncTitle();
  }

  Future<void> setRecordingState(bool recording) async {
    _recording = recording;
    await _rebuildMenu();
    await _syncTitle();
  }

  /// The menu-bar title beside the icon — the ONLY always-on indicator this
  /// app has.
  ///
  /// While you are gaming, Rewind's window is behind a fullscreen game, so
  /// anything the window says about recording state is invisible at exactly
  /// the moment it matters. That is why the app window carries no permanent
  /// recorder chrome (see `RecorderButton`'s doc) and why this exists
  /// instead: the state that has to be readable mid-match is readable where
  /// you can actually see it. The tray already tracked both flags, but only
  /// ever spent them on MENU LABELS, which requires opening the menu — i.e.
  /// exactly the thing a glance is supposed to avoid.
  ///
  /// Deliberately quiet when nothing is happening: an idle title would be
  /// permanent menu-bar clutter for no information.
  Future<void> _syncTitle() async {
    if (Platform.isWindows) return; // no menu-bar title concept
    await trayManager.setTitle(_recording ? '● REC' : '');
  }

  Future<void> _rebuildMenu() => trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Open Rewind'),
        MenuItem(key: 'save', label: 'Save clip now'),
        MenuItem(
            key: 'toggle',
            label: _bufferActive ? 'Pause buffer' : 'Resume buffer'),
        MenuItem(
            key: 'toggleRecording',
            label: _recording ? 'Stop recording' : 'Start recording'),
        MenuItem(key: 'openClips', label: 'Open clips folder'),
        MenuItem.separator(),
        MenuItem(key: 'quit', label: 'Quit Rewind'),
      ]));

  @override
  void onTrayIconMouseDown() => trayManager.popUpContextMenu();

  @override
  Future<void> onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'show':
        _onShowWindow?.call();
      case 'save':
        await _onSaveClip?.call();
      case 'toggle':
        // Capture the target once: the callback may itself call
        // setBufferState, and re-reading the mutated field here would
        // flip the label back and desync the menu from reality.
        final target = !_bufferActive;
        await _onToggleBuffer?.call(target);
        await setBufferState(target);
      case 'toggleRecording':
        await _onToggleRecording?.call();
      case 'openClips':
        await _onOpenClips?.call();
      case 'quit':
        _onQuit?.call();
    }
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
