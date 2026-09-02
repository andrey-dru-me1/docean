import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;

Widget _wrap(Widget child) => MaterialApp(home: child);

DocumentSummary _doc({
  String id = 'doc-1',
  String title = 'Quarterly report',
  List<String> tags = const ['finance'],
  String? mimeType = 'application/pdf',
  String? originalName = 'report.pdf',
}) => DocumentSummary(
  id: id,
  title: title,
  tags: tags,
  mimeType: mimeType,
  originalName: originalName,
);

void main() {
  group('DocumentDetailView', () {
    testWidgets('renders the full extracted content', (tester) async {
      final doc = _doc();
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {
          'doc-1': 'Full body of the quarterly report. ' * 20,
        },
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Quarterly report'), findsOneWidget);
      expect(find.text('ID: doc-1'), findsOneWidget);
      // The full body (not just a snippet) is rendered.
      expect(
        find.textContaining('Full body of the quarterly report'),
        findsOneWidget,
      );
    });

    testWidgets('falls back to decoding raw bytes when there is no text', (
      tester,
    ) async {
      final doc = _doc(mimeType: 'text/plain', originalName: 'notes.txt');
      final service = FakeDocumentService(
        documents: [doc],
        bytesByDocumentId: {
          'doc-1': utf8.encode('Raw file bytes rendered in-app.'),
        },
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Raw file bytes rendered in-app'),
        findsOneWidget,
      );
    });

    testWidgets('adds a tag through the service and updates the UI', (
      tester,
    ) async {
      final doc = _doc(tags: const ['finance']);
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'doc-1': 'Report body'},
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      // The initial tag is editable (InputChip with a delete action).
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('finance'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'tax');
      await tester.tap(find.byIcon(Icons.add));
      await tester.pumpAndSettle();

      // The service persisted the new tag list.
      expect(service.setTagsCount, 1);
      expect(service.lastSetTags, containsAll(['finance', 'tax']));
      // And the view reflects the updated document metadata.
      expect(find.byType(InputChip), findsNWidgets(2));
      expect(find.text('tax'), findsOneWidget);
    });

    testWidgets('removes a tag through the service', (tester) async {
      final doc = _doc(tags: const ['finance', 'tax']);
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'doc-1': 'Report body'},
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      expect(find.byType(InputChip), findsNWidgets(2));

      // Tap the delete affordance on the 'tax' chip.
      final taxChip = find.ancestor(
        of: find.text('tax'),
        matching: find.byType(InputChip),
      );
      final deleteIcon = find.descendant(
        of: taxChip,
        matching: find.byIcon(Icons.clear),
      );
      expect(deleteIcon, findsOneWidget);
      await tester.tap(deleteIcon);
      await tester.pumpAndSettle();

      expect(service.setTagsCount, 1);
      expect(service.lastSetTags, ['finance']);
      expect(find.byType(InputChip), findsOneWidget);
      expect(find.text('tax'), findsNothing);
    });

    testWidgets('opens the raw bytes with the injected external opener', (
      tester,
    ) async {
      final doc = _doc(originalName: 'report.PDF');
      final service = FakeDocumentService(
        documents: [doc],
        bytesByDocumentId: {'doc-1': utf8.encode('%PDF-1.4 fake pdf bytes')},
      );
      String? openedPath;
      final captured = <String>[];
      final temp = Directory.systemTemp.createTempSync('docer-detail-test');
      addTearDown(() => temp.deleteSync(recursive: true));

      await tester.pumpWidget(
        _wrap(
          DocumentDetailView(
            document: doc,
            documentService: service,
            tempDirectory: () async => temp,
            openExternally: (path) async {
              openedPath = path;
              captured.add(path);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The external-open flow writes a real temp file, so it must run in the
      // real-async zone (real file I/O never completes under FakeAsync).
      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.open_in_new));
        // Let the async read-bytes -> write-bytes -> open chain finish.
        while (captured.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      expect(captured, hasLength(1));
      expect(openedPath, endsWith('.PDF'));
    });
  });
}
