import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show DocumentService, FakeDocumentService;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A helper document with fixed fields.
DocumentSummary _doc(
  String id,
  String title, {
  List<String> tags = const [],
  List<String> paths = const [],
}) => DocumentSummary(id: id, title: title, tags: tags, paths: paths);

void main() {
  group('DocumentsScreen', () {
    testWidgets('lists every persisted document from the service', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          _doc(
            'doc-1',
            'Invoice Q3',
            tags: const ['finance'],
            paths: const ['/work'],
          ),
          _doc('doc-2', 'Roadmap', tags: const ['product']),
        ],
        tags: const ['finance', 'product'],
        paths: const ['/work'],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Invoice Q3'), findsOneWidget);
      expect(find.text('Roadmap'), findsOneWidget);
      expect(find.text('finance'), findsWidgets);
      expect(find.text('/work'), findsWidgets);
    });

    testWidgets('shows an empty state when the library has no documents', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: FakeDocumentService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No documents yet'), findsOneWidget);
    });

    testWidgets('tapping a document opens it via the callback', (tester) async {
      final opened = <DocumentSummary>[];
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: FakeDocumentService(
              documents: [_doc('doc-7', 'Contract')],
            ),
            onOpenDocument: opened.add,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Contract'));
      await tester.pumpAndSettle();

      expect(opened, hasLength(1));
      expect(opened.single.id, 'doc-7');
      expect(opened.single.title, 'Contract');
    });

    testWidgets('filters documents by tag chip', (tester) async {
      final service = FakeDocumentService(
        documents: [
          _doc('doc-a', 'Alpha report', tags: const ['finance']),
          _doc('doc-b', 'Beta notes', tags: const ['personal']),
        ],
        tags: const ['finance', 'personal'],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Filter to 'finance' only.
      await tester.tap(find.widgetWithText(FilterChip, 'finance'));
      await tester.pumpAndSettle();

      expect(find.text('Alpha report'), findsOneWidget);
      expect(find.text('Beta notes'), findsNothing);
    });

    testWidgets('reloads the list when the refresh tick is bumped', (
      tester,
    ) async {
      final tick = ValueNotifier<int>(0);
      final service = FakeDocumentService(documents: [_doc('doc-1', 'Before')]);

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: service,
            onOpenDocument: (_) {},
            refreshTick: tick,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Before'), findsOneWidget);
      final callsBefore = service.listCount;

      // Simulate ingestion completing: a new document is now visible.
      service.documents.add(_doc('doc-2', 'After upload'));
      tick.value++;

      await tester.pumpAndSettle();
      expect(service.listCount, greaterThan(callsBefore));
      expect(find.text('After upload'), findsOneWidget);
    });

    testWidgets('shows an error state when the service fails', (tester) async {
      final failing = _FailingDocumentService();

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: failing, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Could not load documents'), findsOneWidget);
    });
  });
}

class _FailingDocumentService implements DocumentService {
  @override
  Future<List<DocumentSummary>> listDocuments() async =>
      throw StateError('repository unavailable');

  @override
  Future<DocumentSummary> getDocument(String id) async =>
      throw StateError('repository unavailable');

  @override
  Future<String?> getContent(String id) async =>
      throw StateError('repository unavailable');

  @override
  Future<List<int>> readBytes(String id) async =>
      throw StateError('repository unavailable');

  @override
  Future<void> setTags(String id, List<String> tags) async =>
      throw StateError('repository unavailable');

  @override
  Future<List<String>> listTags() async =>
      throw StateError('repository unavailable');

  @override
  Future<List<String>> listPaths() async =>
      throw StateError('repository unavailable');

  @override
  Future<void> reindex() async {}
}
