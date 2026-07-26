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

    self.contentMinSize = MainFlutterWindow.minimumContentSize

    // Remember where the user put the window, and only impose the default on
    // a first launch that has nothing saved — otherwise every launch would
    // stomp a size they had deliberately chosen.
    let autosaveName = NSWindow.FrameAutosaveName("RewindMainWindow")
    if !self.setFrameUsingName(autosaveName) {
      self.setContentSize(MainFlutterWindow.defaultContentSize)
      self.center()
    }
    self.setFrameAutosaveName(autosaveName)

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
