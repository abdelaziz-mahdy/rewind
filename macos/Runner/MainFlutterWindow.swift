import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  /// First-launch size. The nib ships 800x600, which is BELOW the 1000pt
  /// threshold at which the nav rail collapses to icons
  /// (`navRailCompactBelow`) — so every first launch opened in the degraded
  /// compact layout, with the game names, clip counts and the recorder's
  /// state label all hidden, and nothing on screen explaining why. Windows
  /// already defaulted to 1280 wide; macOS was the outlier.
  static let defaultContentSize = NSSize(width: 1280, height: 800)

  /// Narrowest layout the UI is actually tested at (the screenshot tour's
  /// width sweep runs 820 / 1280 / 2200). The compact rail is a deliberate
  /// design, so this is well below the collapse threshold — it only stops the
  /// window being dragged narrower than anything anyone has ever looked at.
  static let minimumContentSize = NSSize(width: 820, height: 560)

  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    self.contentViewController = flutterViewController

    // NO frame autosave. It was tried (2026-07-26) and cost a launch: with a
    // saved frame present, `setFrameUsingName` inside `awakeFromNib` left the
    // app running with an AppKit run loop but no Flutter engine at all — no
    // Dart, no logging, no capture, and a window that never appeared. It only
    // looked fine in testing because the first run after the change had no
    // saved frame yet, so it took the other branch.
    //
    // Remembering the window size is worth having, but it belongs somewhere
    // that cannot take the engine down with it.
    let frame = self.frame
    self.contentMinSize = MainFlutterWindow.minimumContentSize
    self.setContentSize(MainFlutterWindow.defaultContentSize)
    self.setFrameOrigin(frame.origin)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
