import 'package:flutter/gestures.dart' show kSecondaryButton;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docean/src/rust/domain.dart' show SavedView;
import 'package:docean/src/ui/document_view.dart' show DocumentSummary;
import 'package:docean/src/ui/documents_screen.dart' show DocumentsScreen;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

DocumentSummary _doc(String id, String title, {List<String> tags = const []}) =>
    DocumentSummary(id: id, title: title, tags: tags);

Future<void> _addTagFilter(WidgetTester tester, String tag) async {
  await tester.enterText(find.byKey(const ValueKey('filter-field')), tag);
  await tester.pump();
  await tester.tap(find.byKey(ValueKey('filter-suggestion-$tag')));
  await tester.pumpAndSettle();
}

FakeDocumentService _service({List<SavedView> views = const []}) =>
    FakeDocumentService(
      documents: [
        _doc('a', 'Alpha', tags: const ['finance', 'tax']),
        _doc('b', 'Beta', tags: const ['finance']),
      ],
      tags: const ['finance', 'tax'],
      savedViews: views,
    );

void main() {
  group('saved filter views', () {
    testWidgets('view chip applies the pinned set; tap again clears', (
      tester,
    ) async {
      final service = _service(
        views: const [
          SavedView(name: 'Money', tags: ['finance', 'tax']),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      final chip = find.byKey(const ValueKey('saved-view-Money'));
      expect(chip, findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();
      // AND of finance+tax: only Alpha remains, both filter chips show.
      expect(find.text('Alpha'), findsOneWidget);
      expect(find.text('Beta'), findsNothing);
      expect(find.byKey(const ValueKey('filter-finance')), findsOneWidget);
      expect(find.byKey(const ValueKey('filter-tax')), findsOneWidget);

      await tester.tap(chip);
      await tester.pumpAndSettle();
      expect(find.text('Beta'), findsOneWidget);
      expect(find.byKey(const ValueKey('filter-finance')), findsNothing);
    });

    testWidgets('star button pins the current filters under a name', (
      tester,
    ) async {
      final service = _service();
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Nothing to pin yet: the button is disabled.
      expect(
        tester
            .widget<IconButton>(find.byKey(const ValueKey('save-view-button')))
            .onPressed,
        isNull,
      );

      await _addTagFilter(tester, 'finance');
      await _addTagFilter(tester, 'tax');

      await tester.tap(find.byKey(const ValueKey('save-view-button')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const ValueKey('saved-view-name-field')),
        'Money',
      );
      await tester.tap(find.text('Save view'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('saved-view-Money')), findsOneWidget);
      expect(service.savedViewWrites, 1);
      expect(service.views.single.tags, ['finance', 'tax']);
    });

    testWidgets('right-click menu deletes a view', (tester) async {
      final service = _service(
        views: const [
          SavedView(name: 'Money', tags: ['finance']),
        ],
      );
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const ValueKey('saved-view-Money')),
        buttons: kSecondaryButton,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete view'));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('saved-view-Money')), findsNothing);
      expect(service.savedViewDeletes, 1);
      expect(service.views, isEmpty);
    });
  });
}
