import 'package:tray_manager/tray_manager.dart';

/// Menu-bar / system-tray presence with quick actions.
///
/// Known issue (v0.1): `tray_manager`'s Windows backend loads the tray icon
/// via `LoadImage(..., IMAGE_ICON, ..., LR_LOADFROMFILE)`, which expects a
/// real `.ico` file. We only ship `assets/tray/tray_icon.png` for now, so on
/// Windows the tray icon may render blank/default; the menu and callbacks
/// still work. A `.ico` variant can be added later without changing this
/// service's API — see `docs/COMPLIANCE.md`/README known-issues.
class TrayService with TrayListener {
  Future<void> Function()? _onSaveClip;
  Future<void> Function(bool)? _onToggleBuffer;
  void Function()? _onShowWindow;
  void Function()? _onQuit;
  bool _bufferActive = true;

  Future<void> init({
    required Future<void> Function() onSaveClip,
    required Future<void> Function(bool startNotStop) onToggleBuffer,
    required void Function() onShowWindow,
    required void Function() onQuit,
  }) async {
    _onSaveClip = onSaveClip;
    _onToggleBuffer = onToggleBuffer;
    _onShowWindow = onShowWindow;
    _onQuit = onQuit;
    trayManager.addListener(this);
    await trayManager.setIcon('assets/tray/tray_icon.png', isTemplate: true);
    await _rebuildMenu();
  }

  Future<void> setBufferState(bool active) async {
    _bufferActive = active;
    await _rebuildMenu();
  }

  Future<void> _rebuildMenu() => trayManager.setContextMenu(Menu(items: [
        MenuItem(key: 'show', label: 'Open Rewind'),
        MenuItem(key: 'save', label: 'Save clip now'),
        MenuItem(
            key: 'toggle',
            label: _bufferActive ? 'Pause buffer' : 'Resume buffer'),
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
        await _onToggleBuffer?.call(!_bufferActive);
        await setBufferState(!_bufferActive);
      case 'quit':
        _onQuit?.call();
    }
  }

  Future<void> dispose() async {
    trayManager.removeListener(this);
    await trayManager.destroy();
  }
}
