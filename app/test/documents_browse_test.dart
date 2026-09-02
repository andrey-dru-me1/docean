import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:docer/src/features/document_preview.dart'
    show DocumentPreviewLoader;
import 'package:docer/src/features/document_service.dart'
    show DocumentService, FakeDocumentService, ReorganizeResult, SuggestionPlan;
import 'package:docer/src/ui/document_preview_view.dart'
    show DocumentPlaceholder, DocumentTilePreview;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docer/src/ui/widgets.dart' show TagChip;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// A tiny valid PNG for thumbnail tests.
Uint8List _pngBytes() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 8, height: 8)));

/// A synchronous (isolate-free) thumbnailer so widget tests resolve under
/// FakeAsync.
Future<Uint8List?> _thumbnailer(Uint8List bytes, int maxDim) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final resized = img.copyResize(
    decoded,
    width: maxDim < decoded.width ? maxDim : decoded.width,
  );
  return Uint8List.fromList(img.encodePng(resized));
}

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

    testWidgets(
      'renders documents in a preview grid with title and tag overlay',
      (tester) async {
        final opened = <DocumentSummary>[];
        final service = FakeDocumentService(
          documents: [
            _doc('g-1', 'Grid report', tags: const ['finance', 'tax']),
            _doc('g-2', 'Grid photo'),
          ],
          tags: const ['finance', 'tax'],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: service,
              onOpenDocument: opened.add,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The browse surface is a responsive grid of large preview tiles.
        expect(find.byType(GridView), findsOneWidget);
        final grid = tester.widget<GridView>(find.byType(GridView));
        final delegate =
            grid.gridDelegate as SliverGridDelegateWithMaxCrossAxisExtent;
        expect(delegate.maxCrossAxisExtent, inInclusiveRange(220, 260));
        expect(delegate.childAspectRatio, closeTo(3 / 4, 0.01));
        expect(find.byType(DocumentTilePreview), findsNWidgets(2));

        // Each tile carries its title and the tag chips overlay the preview.
        expect(find.text('Grid report'), findsOneWidget);
        expect(find.text('Grid photo'), findsOneWidget);
        expect(find.widgetWithText(TagChip, 'finance'), findsOneWidget);
        expect(find.widgetWithText(TagChip, 'tax'), findsOneWidget);

        // Tapping a tile still opens the document.
        await tester.tap(find.text('Grid report'));
        await tester.pumpAndSettle();
        expect(opened, hasLength(1));
        expect(opened.single.id, 'g-1');
      },
    );

    testWidgets(
      'shows an image thumbnail for image documents and a placeholder for '
      'text documents',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            const DocumentSummary(
              id: 'doc-img',
              title: 'Photo',
              tags: ['media'],
              mimeType: 'image/png',
            ),
            const DocumentSummary(
              id: 'doc-txt',
              title: 'Readme',
              mimeType: 'text/plain',
            ),
          ],
          bytesByDocumentId: {'doc-img': _pngBytes()},
        );
        final loader = DocumentPreviewLoader(
          bytesSource: (id) => service.readBytes(id),
          imageThumbnailer: ({required bytes, required maxDim}) async =>
              _thumbnailer(bytes, maxDim),
          pdfSupport: () async => false,
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: service,
              onOpenDocument: (_) {},
              previewLoader: loader,
            ),
          ),
        );
        await tester.pumpAndSettle();

        // The image doc renders a real Image thumbnail; the text doc keeps the
        // deterministic color/glyph placeholder tile. Both are grid tiles now.
        expect(find.byType(DocumentTilePreview), findsNWidgets(2));
        expect(find.byType(Image), findsOneWidget);
        expect(find.byType(DocumentPlaceholder), findsOneWidget);
      },
    );

    testWidgets('a broken image thumbnail never bricks the list', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          const DocumentSummary(
            id: 'doc-bad',
            title: 'Broken',
            mimeType: 'image/png',
          ),
        ],
        bytesByDocumentId: {
          'doc-bad': Uint8List.fromList([9, 9, 9]),
        },
      );
      final loader = DocumentPreviewLoader(
        bytesSource: (id) => service.readBytes(id),
        imageThumbnailer: ({required bytes, required maxDim}) async =>
            _thumbnailer(bytes, maxDim),
        pdfSupport: () async => false,
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: service,
            onOpenDocument: (_) {},
            previewLoader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The list still shows the document, and the preview degraded to the
      // placeholder instead of throwing.
      expect(find.text('Broken'), findsOneWidget);
      expect(find.byType(DocumentPlaceholder), findsWidgets);
      expect(tester.takeException(), isNull);
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
  Future<void> updateTitle(String id, String title) async =>
      throw StateError('repository unavailable');

  @override
  Future<SuggestionPlan> suggestMetadata(String id) async =>
      throw StateError('repository unavailable');

  @override
  Future<ReorganizeResult> reorganizeAll() async =>
      throw StateError('repository unavailable');

  @override
  Future<SuggestionPlan> reorganizeOne(String id) async =>
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
