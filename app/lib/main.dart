import 'package:flutter/material.dart';

import 'src/app.dart';
import 'src/rust/frb_generated.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load the native `docer-core` library and initialize the bridge.
  await RustLib.init();
  runApp(const DocerApp());
}
