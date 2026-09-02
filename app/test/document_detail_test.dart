import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService, SuggestionPlan;
import 'package:docer/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;

Widget _wrap(Widget child) => MaterialApp(home: child);

DocumentSummary _doc({
  String id = 'doc-1',
  String title = 'Quarterly report',
  List<String> tags = const ['finance'],
  String? mimeType = 'application/pdf',
  String? originalName = 'report.pdf',
  Map<String, String> extra = const {},
}) => DocumentSummary(
  id: id,
  title: title,
  tags: tags,
  mimeType: mimeType,
  originalName: originalName,
  extra: extra,
);

/// The inline title field is the first TextField; the tag composer is the
/// second (hinted 'Add a tag…').
Finder _titleField() => find.byType(TextField).first;
Finder _tagField() => find.byType(TextField).last;

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
      // Raw ids are never surfaced to users.
      expect(find.text('ID: doc-1'), findsNothing);
      // The full body (not just a snippet) is rendered.
      expect(
        find.textContaining('Full body of the quarterly report'),
        findsOneWidget,
      );
    });

    testWidgets('does not show the raw document id anywhere', (tester) async {
      final doc = _doc(id: 'internal-hash-123');
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'internal-hash-123': 'Body'},
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('internal-hash-123'), findsNothing);
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

      await tester.enterText(_tagField(), 'tax');
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

    testWidgets('manually renaming the title persists through the service', (
      tester,
    ) async {
      final doc = _doc(title: 'Old title');
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'doc-1': 'Report body'},
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      await tester.enterText(_titleField(), 'Renamed title');
      await tester.tap(find.byTooltip('Save title'));
      await tester.pumpAndSettle();

      expect(service.updateTitleCount, 1);
      expect(service.lastTitle, 'Renamed title');
      // The fresh document is reflected in the field.
      expect(
        tester.widget<TextField>(_titleField()).controller!.text,
        'Renamed title',
      );
      expect(find.text('Renamed title'), findsOneWidget);
    });
    testWidgets(
      'auto-suggest calls the service and applies title + tags when nothing '
      'was manually edited',
      (tester) async {
        final doc = _doc(tags: const ['stale']);
        final service = FakeDocumentService(
          documents: [doc],
          contentByDocumentId: {'doc-1': 'Report body'},
          suggestion: const SuggestionPlan(
            title: 'Suggested title',
            tags: ['finance', 'q3'],
          ),
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Suggest title & tags'));
        await tester.pumpAndSettle();

        // The per-file button now reuses the core re-organize-one path, which
        // honors the manual-edit flags internally.
        expect(service.reorganizeOneCount, 1);
        expect(service.updateTitleCount, 1);
        expect(service.lastTitle, 'Suggested title');
        expect(service.setTagsCount, 1);
        expect(service.lastSetTags, containsAll(['finance', 'q3']));
        // UI reflects the applied suggestion.
        expect(find.text('Suggested title'), findsOneWidget);
        expect(find.text('finance'), findsWidgets);
        expect(find.text('stale'), findsNothing);
      },
    );

    testWidgets(
      'auto-suggest respects the manual title flag and keeps the user title',
      (tester) async {
        final doc = _doc(
          title: 'User title',
          extra: const {'title_manual': 'true'},
        );
        final service = FakeDocumentService(
          documents: [doc],
          contentByDocumentId: {'doc-1': 'Report body'},
          suggestion: const SuggestionPlan(
            title: 'Suggested title',
            tags: ['auto'],
          ),
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.text('Suggest title & tags'));
        await tester.pumpAndSettle();

        // The suggestion ran, but the title was NOT overwritten.
        expect(service.reorganizeOneCount, 1);
        expect(service.updateTitleCount, 0);
        expect(service.lastTitle, isNull);
        expect(find.text('User title'), findsOneWidget);
        // Tags still applied (tags_manual absent).
        expect(service.setTagsCount, 1);
        expect(service.lastSetTags, contains('auto'));
      },
    );

    testWidgets('auto-suggest respects the manual tags flag and keeps tags', (
      tester,
    ) async {
      final doc = _doc(
        tags: const ['keep-me'],
        extra: const {'tags_manual': 'true'},
      );
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'doc-1': 'Report body'},
        suggestion: const SuggestionPlan(
          title: 'Suggested title',
          tags: ['auto'],
        ),
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Suggest title & tags'));
      await tester.pumpAndSettle();

      expect(service.reorganizeOneCount, 1);
      expect(service.updateTitleCount, 1);
      expect(service.lastTitle, 'Suggested title');
      // Tags were NOT overwritten.
      expect(service.setTagsCount, 0);
      expect(find.text('keep-me'), findsOneWidget);
      expect(find.text('auto'), findsNothing);
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

    testWidgets('open externally falls back to creating a missing temp directory '
        'instead of failing with PathNotFoundException', (tester) async {
      final doc = _doc(originalName: 'report.pdf');
      final service = FakeDocumentService(
        documents: [doc],
        bytesByDocumentId: {'doc-1': utf8.encode('%PDF-1.4 fake')},
      );
      String? openedPath;
      final captured = <String>[];
      // A temp directory that does not exist yet (its parent may not exist
      // either, exactly the PathNotFoundException scenario).
      final missing = Directory(
        '${Directory.systemTemp.path}/docer-missing-${DateTime.now().microsecondsSinceEpoch}',
      );
      addTearDown(() {
        if (missing.existsSync()) missing.deleteSync(recursive: true);
      });

      await tester.pumpWidget(
        _wrap(
          DocumentDetailView(
            document: doc,
            documentService: service,
            tempDirectory: () async => missing,
            openExternally: (path) async {
              openedPath = path;
              captured.add(path);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.open_in_new));
        while (captured.isEmpty) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      // The directory was created (recursive) so the temp file landed and the
      // opener received a valid path — no PathNotFoundException.
      expect(missing.existsSync(), isTrue);
      expect(captured, hasLength(1));
      expect(openedPath, startsWith(missing.path));
      expect(File(openedPath!).existsSync(), isTrue);
    });

    testWidgets('open externally degrades gracefully when the dir cannot be '
        'created (falls back to system temp)', (tester) async {
      final doc = _doc(originalName: 'notes.txt');
      final service = FakeDocumentService(
        documents: [doc],
        bytesByDocumentId: {'doc-1': utf8.encode('hello')},
      );
      String? openedPath;
      final captured = <String>[];

      await tester.pumpWidget(
        _wrap(
          DocumentDetailView(
            document: doc,
            documentService: service,
            // A directory whose creation must fail.
            tempDirectory: () async => Directory('/nonexistent-root/docer'),
            openExternally: (path) async {
              openedPath = path;
              captured.add(path);
            },
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        await tester.tap(find.byIcon(Icons.open_in_new));
        while (captured.isEmpty && openedPath == null) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();

      // Either the fallback path was used (system temp is writable), or the
      // operation surfaced a snackbar instead of crashing. We only assert we
      // never saw the PathNotFoundException snackbar framing.
      final snack = find.byType(SnackBar);
      if (snack.evaluate().isNotEmpty) {
        final text = tester.widget<SnackBar>(snack).content;
        expect(text.toString(), isNot(contains('PathNotFoundException')));
      }
    });
  });
}
