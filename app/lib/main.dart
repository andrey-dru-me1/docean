import 'package:flutter/material.dart';
import 'package:flutter_rust_bridge/flutter_rust_bridge_for_generated.dart';

import 'src/app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the native `docer-core` library and initialize the bridge.
  await RustLib.init(
    externalLibrary: ExternalLibrary.process(iKnowHowToUseIt: true),
  );
  runApp(const DocerApp());
}
