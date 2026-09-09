library;

import 'dart:async';

import 'package:flutter/services.dart';

/// Persisted Apple App Sandbox access to the library folder.
///
/// The macOS app runs sandboxed; a folder picked through the directory picker
/// is only readable while a security-scoped access (backed by a bookmark) is
/// active. The native side stores a bookmark on [bookmarkLibraryFolder] and
/// restarts the access on [restoreLibraryScope] at every launch.
class SecurityScopeService {
  const SecurityScopeService();

  static const MethodChannel _channel = MethodChannel('docean/security_scope');

  /// Persist a security-scoped bookmark for [path] and keep the panel-granted
  /// access alive. Returns `false` when bookmarking failed (no sandbox, test
  /// runner, or a plugin-less platform) — callers treat that as best-effort.
  Future<bool> bookmark(String path) async {
    try {
      return await _channel.invokeMethod<bool>('bookmark', {'path': path}) ??
          false;
    } on MissingPluginException {
      return false;
    }
  }

  /// Restart a persisted security-scoped access. Returns the resolved folder
  /// path, or `null` when no bookmark exists or it went stale (folder moved:
  /// the user has to re-pick).
  Future<String?> restore() async {
    try {
      return await _channel.invokeMethod<String>('restore');
    } on MissingPluginException {
      return null;
    }
  }
}

/// Best-effort module-level wrappers used by startup and dialog call sites.
const SecurityScopeService securityScope = SecurityScopeService();

Future<bool> bookmarkLibraryFolder(String path) => securityScope.bookmark(path);
Future<String?> restoreLibraryScope() => securityScope.restore();
