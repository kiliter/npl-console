import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(NSRect(x: windowFrame.origin.x, y: windowFrame.origin.y, width: 1380, height: 900), display: true)
    self.minSize = NSSize(width: 800, height: 650)
    self.title = "无纸化维护中心"

    RegisterGeneratedPlugins(registry: flutterViewController)
    // 仅响应用户点击全屏预览，返回原状态以便退出时恢复窗口。
    let previewChannel = FlutterMethodChannel(name: "cn.agilestar.maintenance/window", binaryMessenger: flutterViewController.engine.binaryMessenger)
    previewChannel.setMethodCallHandler { [weak self] call, result in
      guard let window = self, call.method == "setFullscreen",
            let args = call.arguments as? [String: Any], let enabled = args["enabled"] as? Bool else {
        result(FlutterMethodNotImplemented)
        return
      }
      let wasFullscreen = window.styleMask.contains(.fullScreen)
      if wasFullscreen != enabled { window.toggleFullScreen(nil) }
      result(wasFullscreen)
    }


    super.awakeFromNib()
  }
}
