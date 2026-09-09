import Cocoa
import FlutterMacOS

class MainFlutterWindow: NSWindow {
  override func awakeFromNib() {
    let flutterViewController = FlutterViewController()
    let windowFrame = self.frame
    self.contentViewController = flutterViewController
    self.setFrame(windowFrame, display: true)

    // Sandbox security scope: the app runs with App Sandbox enabled, so the
    // library folder picked through the directory picker is only reachable
    // while a security-scoped access is active. The access must be persisted
    // as a security-scoped bookmark and restarted at every launch.
    let securityChannel = FlutterMethodChannel(
      name: "docean/security_scope",
      binaryMessenger: flutterViewController.engine.binaryMessenger
    )
    securityChannel.setMethodCallHandler { call, result in
      let bookmarkKey = "docean.library.bookmark"

      switch call.method {
      case "bookmark":
        guard let args = call.arguments as? [String: Any],
              let path = args["path"] as? String else {
          result(FlutterError(code: "bad-args", message: "path expected", details: nil))
          return
        }
        let url = URL(fileURLWithPath: path)
        do {
          let data = try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
          )
          UserDefaults.standard.set(data.base64EncodedString(), forKey: bookmarkKey)
          // Keep the panel-granted access alive until the next launch resolves
          // the bookmark.
          _ = url.startAccessingSecurityScopedResource()
          result(true)
        } catch {
          result(FlutterError(code: "bookmark-failed", message: error.localizedDescription, details: nil))
        }

      case "restore":
        guard let b64 = UserDefaults.standard.string(forKey: bookmarkKey),
              let data = Data(base64Encoded: b64) else {
          result(nil)
          return
        }
        var stale = false
        do {
          let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &stale
          )
          let started = url.startAccessingSecurityScopedResource()
          result(started ? url.path : nil)
        } catch {
          // Bookmark stale or unusable (folder moved/renamed): the user must
          // re-pick the folder.
          result(nil)
        }

      default:
        result(FlutterMethodNotImplemented)
      }
    }

    RegisterGeneratedPlugins(registry: flutterViewController)

    super.awakeFromNib()
  }
}
