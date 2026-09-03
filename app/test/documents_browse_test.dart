import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:docer/src/features/document_preview.dart'
    show DocumentPreviewLoader;
import 'package:docer/src/features/document_service.dart'
    show BulkOrganizer, FakeDocumentService, ReorganizeResult, SuggestionPlan;
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
        // Tags appear on the preview tile overlay AND in the filter bar, so
        // scope to GridView descendants to check only the tile overlay chips.
        expect(
          find.descendant(
            of: find.byType(GridView),
            matching: find.widgetWithText(TagChip, 'finance'),
          ),
          findsOneWidget,
        );
        expect(
          find.descendant(
            of: find.byType(GridView),
            matching: find.widgetWithText(TagChip, 'tax'),
          ),
          findsOneWidget,
        );

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

    testWidgets('enters selection mode and toggles tiles via the toolbar', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [_doc('s-1', 'Sel one'), _doc('s-2', 'Sel two')],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // No selection bar in browse mode, but the checkbox is always visible.
      expect(find.byKey(const ValueKey('selection-bar')), findsNothing);
      expect(find.byKey(const ValueKey('select-check-s-1')), findsOneWidget);

      // The 'Select all' button enters selection mode with all docs selected.
      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      expect(find.text('2 selected'), findsOneWidget);
      // Tiles show the selection checkbox overlay.
      expect(find.byKey(const ValueKey('select-check-s-1')), findsOneWidget);
      expect(find.byKey(const ValueKey('select-check-s-2')), findsOneWidget);

      // Tapping a checkbox deselects that document.
      await tester.tap(find.byKey(const ValueKey('select-check-s-1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      // Long-pressing a tile from browse mode also enters selection mode.
      await tester.tap(find.byKey(const ValueKey('exit-selection')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-bar')), findsNothing);

      await tester.longPress(find.text('Sel two'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
      expect(find.text('1 selected'), findsOneWidget);
    });

    testWidgets(
      'tapping a tile checkbox in browse mode enters selection mode',
      (tester) async {
        final opened = <DocumentSummary>[];
        final service = FakeDocumentService(documents: [_doc('b-1', 'Browse one')]);

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: opened.add),
          ),
        );
        await tester.pumpAndSettle();

        // Tapping the always-visible checkbox must NOT open the document
        // (no sidebar/detail navigation); it enters selection mode with the
        // tapped document pre-selected.
        await tester.tap(find.byKey(const ValueKey('select-check-b-1')));
        await tester.pumpAndSettle();

        expect(opened, isEmpty);
        expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
        expect(find.text('1 selected'), findsOneWidget);
      },
    );

    testWidgets('select-all selects every currently-filtered document', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          _doc('f-1', 'Alpha report', tags: const ['finance']),
          _doc('f-2', 'Beta report', tags: const ['finance']),
          _doc('f-3', 'Gamma notes', tags: const ['personal']),
        ],
        tags: const ['finance', 'personal'],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Filter to the 'finance' tag only: 2 of the 3 documents match.
      await tester.tap(find.widgetWithText(FilterChip, 'finance'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      // Deselect one so the toolbar button reads "Select all" (not "Clear").
      await tester.tap(find.byKey(const ValueKey('select-check-f-1')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('select-all')));
      await tester.pumpAndSettle();

      // Only the filtered docs are selected (the 'personal' one is hidden).
      expect(find.text('2 selected'), findsOneWidget);
    });

    testWidgets('Clear deselects everything after Select all', (tester) async {
      final service = FakeDocumentService(
        documents: [
          _doc('c-1', 'Clear one'),
          _doc('c-2', 'Clear two'),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      // Enter selection mode with everything selected.
      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // The toolbar button now reads "Clear"; tapping it deselects everything.
      expect(find.text('Clear'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('select-all')));
      await tester.pumpAndSettle();

      expect(find.text('0 selected'), findsOneWidget);
      expect(find.text('Clear'), findsNothing);
      expect(find.text('Select all'), findsOneWidget);
    });

    testWidgets('bulk add/remove tag touches every selected document', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          _doc('t-1', 'Tag one', tags: const ['existing']),
          _doc('t-2', 'Tag two'),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();
      expect(find.text('2 selected'), findsOneWidget);

      // Add tag 'work' to both docs.
      await tester.tap(find.byKey(const ValueKey('bulk-add-tag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'work');
      await tester.tap(find.byKey(const ValueKey('confirm-tag-name')));
      await tester.pumpAndSettle();

      expect(service.bulkAdds, isNotEmpty);
      expect(service.bulkAdds.last, contains('work'));
      expect(service.bulkTagIds, containsAll(['t-1', 't-2']));
      // Existing tags were honored: 'existing' + appended 'work'.
      expect(
        service.documents.firstWhere((d) => d.id == 't-1').tags,
        containsAll(['existing', 'work']),
      );

      // Remove tag 'existing' from every selected doc.
      await tester.tap(find.byKey(const ValueKey('bulk-remove-tag')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'existing');
      await tester.tap(find.byKey(const ValueKey('confirm-tag-name')));
      await tester.pumpAndSettle();

      expect(service.bulkRemoves, isNotEmpty);
      expect(service.bulkRemoves.last, contains('existing'));
      expect(
        service.documents.firstWhere((d) => d.id == 't-1').tags,
        isNot(contains('existing')),
      );
    });

    testWidgets('bulk delete requires confirmation then deletes selected', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [_doc('d-1', 'Delete me'), _doc('d-2', 'Keep me')],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();
      // 'Select all' auto-selects both; deselect d-2 to keep only d-1.
      await tester.tap(find.byKey(const ValueKey('select-check-d-2')));
      await tester.pumpAndSettle();
      expect(find.text('1 selected'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('bulk-delete')));
      await tester.pumpAndSettle();

      // The confirmation dialog appears before any deletion.
      expect(find.text('Delete 1 document?'), findsOneWidget);
      expect(find.text('This cannot be undone.'), findsOneWidget);
      expect(service.deleteCount, 0);

      await tester.tap(find.byKey(const ValueKey('confirm-bulk-delete')));
      await tester.pumpAndSettle();

      expect(service.deletedIds, ['d-1']);
      expect(find.text('Delete me'), findsNothing);
      expect(find.text('Keep me'), findsOneWidget);
    });

    testWidgets('bulk suggest tags runs async and respects manual flags', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          _doc('g-1', 'Auto doc'),
          DocumentSummary(
            id: 'g-2',
            title: 'Manual doc',
            tags: const ['mine'],
            extra: const {'title_manual': 'true', 'tags_manual': 'true'},
          ),
        ],
        suggestion: const SuggestionPlan(
          title: 'Suggested title',
          tags: ['suggested-a', 'suggested-b'],
        ),
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bulk-suggest-tags')));
      await tester.pumpAndSettle();

      // The service ran suggestTags once per selected document.
      expect(service.suggestTagsCount, 2);
      // The auto document received the suggested tags; the manually-tagged one
      // was left alone (tags_manual was set), honoring the flag.
      final auto = service.documents.firstWhere((d) => d.id == 'g-1');
      final manual = service.documents.firstWhere((d) => d.id == 'g-2');
      expect(auto.tags, containsAll(['suggested-a', 'suggested-b']));
      expect(manual.tags, ['mine']);
    });

    testWidgets('bulk suggest title runs async and respects manual flags', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [
          _doc('h-1', 'Auto title'),
          DocumentSummary(
            id: 'h-2',
            title: 'Manual title',
            extra: const {'title_manual': 'true', 'tags_manual': 'true'},
          ),
        ],
        suggestion: const SuggestionPlan(title: 'Suggested title', tags: []),
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bulk-suggest-title')));
      await tester.pumpAndSettle();

      expect(service.suggestTitleCount, 2);
      final auto = service.documents.firstWhere((d) => d.id == 'h-1');
      final manual = service.documents.firstWhere((d) => d.id == 'h-2');
      expect(auto.title, 'Suggested title');
      expect(manual.title, 'Manual title'); // title_manual honored.
    });

    testWidgets('bulk reorganize appears in the toolbar and runs the pass', (
      tester,
    ) async {
      final service = FakeDocumentService(documents: [_doc('r-1', 'Re-org')]);
      final organizer = _FakeBulkOrganizer(
        () => const ReorganizeResult(total: 1, updated: 1, skipped: 0),
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: service,
            onOpenDocument: (_) {},
            bulkOrganizer: organizer,
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bulk-reorganize')));
      await tester.pumpAndSettle();

      expect(organizer.calls, 1);
      expect(find.textContaining('Re-organized: 1 updated'), findsOneWidget);
    });

    testWidgets('bulk suggest shows a corner progress notifier while running', (
      tester,
    ) async {
      final gate = Completer<void>();
      final service = _GatedSuggestService(
        gate: gate,
        documents: [_doc('p-1', 'Progress one'), _doc('p-2', 'Progress two')],
        suggestion: const SuggestionPlan(title: 'Suggested', tags: ['tag']),
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('select-documents')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('bulk-suggest-tags')));
      // The pass is async: while the gate is held, the corner notifier reports
      // progress ('0/2') instead of blocking the grid.
      await tester.pump();
      await tester.pump();

      expect(find.textContaining('0/2'), findsOneWidget);
      expect(find.textContaining('Suggesting tags'), findsOneWidget);

      // Let the pass finish.
      gate.complete();
      await tester.pumpAndSettle();

      expect(service.suggestTagsCount, 2);
      expect(find.textContaining('0/2'), findsNothing);
    });

    testWidgets(
      'tapping a tag on a preview tile toggles the tag filter',
      (tester) async {
        final opened = <DocumentSummary>[];
        final service = FakeDocumentService(
          documents: [
            _doc('doc-f', 'Finance report', tags: const ['finance']),
            _doc('doc-p', 'Personal notes', tags: const ['personal']),
            _doc('doc-b', 'Both tags', tags: const ['finance', 'personal']),
          ],
          tags: const ['finance', 'personal'],
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

        // All three documents are visible initially.
        expect(find.text('Finance report'), findsOneWidget);
        expect(find.text('Personal notes'), findsOneWidget);
        expect(find.text('Both tags'), findsOneWidget);

        // Tap the 'finance' tag on the first preview tile to filter.
        await tester.tap(
          find.byKey(const ValueKey('tile-tag-tap-finance')).first,
        );
        await tester.pumpAndSettle();

        // Only documents with the 'finance' tag remain visible.
        expect(find.text('Finance report'), findsOneWidget);
        expect(find.text('Personal notes'), findsNothing);
        expect(find.text('Both tags'), findsOneWidget);

        // The filter bar tag chip for 'finance' is now selected.
        expect(
          find.widgetWithText(FilterChip, 'finance'),
          findsOneWidget,
        );

        // Tapping the same tag on a tile again should REMOVE the filter.
        await tester.tap(
          find.byKey(const ValueKey('tile-tag-tap-finance')).first,
        );
        await tester.pumpAndSettle();

        // All documents are visible again.
        expect(find.text('Finance report'), findsOneWidget);
        expect(find.text('Personal notes'), findsOneWidget);
        expect(find.text('Both tags'), findsOneWidget);

        // Tapping a tag on a tile does NOT open the document.
        expect(opened, isEmpty);
      },
    );
  });
}

/// A [FakeDocumentService] whose suggestion runs complete only when the
/// injected [Completer] resolves — used to assert the bulk suggest pass is
/// async and reports progress via the corner notifier.
class _GatedSuggestService extends FakeDocumentService {
  _GatedSuggestService({
    required this.gate,
    super.documents = const [],
    super.suggestion,
  });

  final Completer<void> gate;

  @override
  Future<SuggestionPlan> suggestTags(String id) async {
    await gate.future;
    return super.suggestTags(id);
  }

  @override
  Future<SuggestionPlan> suggestTitle(String id) async {
    await gate.future;
    return super.suggestTitle(id);
  }
}

/// A [BulkOrganizer] that counts its invocations and returns an injected
/// result.
class _FakeBulkOrganizer implements BulkOrganizer {
  _FakeBulkOrganizer(this._result);

  final ReorganizeResult Function() _result;
  int calls = 0;
  Set<String>? lastSelectedIds;

  @override
  Future<ReorganizeResult> reorganizeAll() async {
    calls++;
    return _result();
  }

  @override
  Future<ReorganizeResult> reorganizeSelected(Set<String> ids) async {
    calls++;
    lastSelectedIds = ids;
    return _result();
  }
}

/// A [FakeDocumentService] whose library listing fails, used to assert the
/// grid's error state without implementing the whole interface.
class _FailingDocumentService extends FakeDocumentService {
  @override
  Future<List<DocumentSummary>> listDocuments() async =>
      throw StateError('repository unavailable');
}
