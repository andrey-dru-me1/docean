import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/rust/api/search.dart'
    show SearchMode, SearchRequestDto, searchIndexDocument, searchQuery;
import 'package:docer/src/rust/frb_generated.dart';

/// Real end-to-end tests: load the native `docer-core` library and exercise the
/// search + chat + provider UI through the bridge.
///
/// Run on a desktop target, e.g. `flutter test integration_test -d macos`.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async => await RustLib.init());

  testWidgets('shell shows the engine status chip', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(const DocerApp());
    await tester.pumpAndSettle();

    expect(find.textContaining('Engine OK'), findsOneWidget);
    // The navigation destinations are present.
    expect(find.text('Search'), findsWidgets);
    expect(find.text('Chat'), findsWidgets);
  });

  testWidgets('search bridge indexes text and returns highlights', (
    WidgetTester tester,
  ) async {
    searchIndexDocument(documentId: 'it-doc', text: 'Integration test fox');
    final hits = searchQuery(
      req: SearchRequestDto(
        text: 'fox',
        mode: SearchMode.exact,
        tags: const [],
        paths: const [],
      ),
    );
    expect(hits, isNotEmpty);
    expect(hits.first.documentId, 'it-doc');
    expect(hits.first.snippet, contains('fox'));
  });
}
