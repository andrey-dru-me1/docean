import Cocoa
import FlutterMacOS
import QuickLookThumbnailing

@main
class AppDelegate: FlutterAppDelegate {
  override func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    return true
  }

  override func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool {
    return true
  }

  override func applicationDidFinishLaunching(_ notification: Notification) {
    // Register the QuickLook docx preview handler so the Flutter side can
    // render a real page-1 thumbnail (the same one Finder shows) without
    // bundling any converter. See `docx_rasterizer.dart`.
    let controller: FlutterViewController =
      mainFlutterWindow?.contentViewController as! FlutterViewController
    let channel = FlutterMethodChannel(
      name: "com.docer.docx_preview/quicklook",
      binaryMessenger: controller.engine.binaryMessenger)
    channel.setMethodCallHandler { call, result in
      guard call.method == "renderDocxPreview" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let args = call.arguments as? [String: Any],
        let bytes = args["bytes"] as? FlutterStandardTypedData
      else {
        result(nil)
        return
      }
      self.renderDocxPreview(bytes: bytes.data, result: result)
    }
    super.applicationDidFinishLaunching(notification)
  }

  /// Renders a docx file's first page to a PNG via QuickLook.
  ///
  /// Writes `bytes` to a temp `.docx` file, asks `QLThumbnailGenerator` for a
  /// page-sized thumbnail, and returns the PNG data (or `nil` on failure,
  /// mirroring the Dart side's graceful tier fallback).
  private func renderDocxPreview(
    bytes: Data,
    result: @escaping FlutterResult
  ) {
    let tempDir = FileManager.default.temporaryDirectory
    let tempUrl = tempDir.appendingPathComponent("docx_preview_\(UUID().uuidString).docx")
    do {
      try bytes.write(to: tempUrl, options: .atomic)
    } catch {
      result(nil)
      return
    }

    let request = QLThumbnailGenerator.Request(
      fileAt: tempUrl,
      size: CGSize(width: 512, height: 512),
      scale: 1.0,
      representationTypes: [.thumbnail])
    QLThumbnailGenerator.shared.generateBestRepresentation(for: request) {
      representation, error in
      defer { try? FileManager.default.removeItem(at: tempUrl) }
      guard let pngData = representation?.cgImage.pngData() else {
        result(nil)
        return
      }
      result(FlutterStandardTypedData(bytes: pngData))
    }
  }
}

extension CGImage {
  /// PNG-encode the image via `NSBitmapImageRep` (macOS 10.14+ / AppKit).
  func pngData() -> Data? {
    let rep = NSBitmapImageRep(cgImage: self)
    return rep.representation(using: .png, properties: [:])
  }
}