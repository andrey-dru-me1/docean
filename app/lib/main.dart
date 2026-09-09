import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/app.dart';
import 'src/features/security_scope.dart'
    show bookmarkLibraryFolder, restoreLibraryScope;
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the native `docean_core` library and initialize the bridge.
  await RustLib.init(
    externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
  );
  runApp(
    DoceanApp(
      // App Sandbox: persist + restore the library folder's security-scoped
      // access (a plain path alone is unreadable across launches).
      libraryBookmarkFolder: bookmarkLibraryFolder,
      libraryScopeRestore: restoreLibraryScope,
    ),
  );
}
