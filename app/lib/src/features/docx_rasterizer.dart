/// macOS QuickLook docx rasterizer.
///
/// Sends the raw docx bytes to the Swift [`QLThumbnailGenerator`] handler in
/// `AppDelegate.swift` via a `MethodChannel` and receives back a PNG
/// thumbnail of the first page — the exact thumbnail Finder shows.
///
/// Injectable via [`DocumentPreviewLoader.docxRasterizer`] so widget tests
/// never invoke the native channel.
library;

import 'dart:typed_data';

import 'package:flutter/services.dart' show MethodChannel;

/// The `MethodChannel` used to communicate with the Swift QuickLook handler
/// in `AppDelegate.swift`. The channel name matches the string registered on
/// the native side.
const MethodChannel _quickLookChannel = MethodChannel(
  'com.docer.docx_preview/quicklook',
);

/// Render the first page of a docx via macOS QuickLook.
///
/// Writes the raw bytes to the Swift handler via [`_quickLookChannel`], and
/// returns the resulting PNG bytes — or `null` if anything fails (channel
/// error, handler failure, or non-macOS platform).
Future<Uint8List?> quickLookDocxRasterizer(Uint8List bytes) async {
  try {
    final result = await _quickLookChannel.invokeMethod<Uint8List>(
      'renderDocxPreview',
      {'bytes': bytes},
    );
    return result;
  } catch (_) {
    // Channel not available (test runner, non-macOS), handler failure, or
    // temp file write error — degrade gracefully.
    return null;
  }
}
