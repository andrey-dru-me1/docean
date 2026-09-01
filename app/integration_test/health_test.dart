import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/rust/frb_generated.dart';

/// Real end-to-end test: loads the native `docer-core` library and calls the
/// Rust `health_check` function through the bridge.
///
/// Run on a desktop target, e.g. `flutter test integration_test -d macos`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => await RustLib.init());

  testWidgets('calls the Rust health check from Dart', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DocerApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Rust core: OK'), findsOneWidget);
    expect(find.textContaining('docer-core'), findsOneWidget);
  });
}
