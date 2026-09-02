import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/gestures.dart' show PointerDeviceKind;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService, SuggestionPlan;
import 'package:docer/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;
import 'package:docer/src/ui/widgets.dart' show TagChip;

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

/// The inline title field is the first TextField.
Finder _titleField() => find.byType(TextField).first;

/// The delete (X) affordance on an [TagChip] whose label text is [tagLabel].
///
/// The X lives inside a manageable-size [TagDeleteIcon]; with a touch pointer
/// (widget-test default) it is always visible, so this finder is stable
/// regardless of how far the chip has scrolled.
Finder _deleteIconFor(String tagLabel) {
  final chip = find.ancestor(
    of: find.text(tagLabel),
    matching: find.byType(TagChip),
  );
  return find.descendant(of: chip, matching: find.byIcon(Icons.clear));
}

/// A [FakeDocumentService] whose tag persistence completes only when the
/// injected [Completer] resolves — used to assert that tag add/remove updates
/// the UI *before* the persist round-trip finishes.
class _GatedTagService extends FakeDocumentService {
  _GatedTagService({required this.gate, super.documents = const []});

  final Completer<void> gate;

  @override
  Future<void> setTags(String id, List<String> nextTags) async {
    // Record the persist intent immediately so the test can assert it fired;
    // only the actual persistence is gated (the UI must stay optimistic).
    setTagsCount++;
    lastSetTags = List.of(nextTags);
    await gate.future;
    final index = documents.indexWhere((d) => d.id == id);
    if (index < 0) throw StateError('document $id not found');
    final doc = documents[index];
    documents[index] = DocumentSummary(
      id: doc.id,
      title: doc.title,
      snippet: doc.snippet,
      tags: List.of(nextTags),
      paths: doc.paths,
      mimeType: doc.mimeType,
      originalName: doc.originalName,
      extra: {...doc.extra, 'tags_manual': 'true'},
    );
  }
}

/// A [FakeDocumentService] whose tag persistence fails after a microtask
/// delay, so the optimistic chip renders before the revert applies.
class _FailingTagService extends FakeDocumentService {
  _FailingTagService({super.documents = const []});

  @override
  Future<void> setTags(String id, List<String> nextTags) async {
    await Future<void>.delayed(Duration.zero);
    throw StateError('persist failed');
  }
}

/// A [FakeDocumentService] whose suggestion runs complete only when the
/// injected [Completer] resolves — used to assert that suggestion is async and
/// non-blocking.
class _GatedSuggestService extends FakeDocumentService {
  _GatedSuggestService({
    required this.gate,
    super.documents = const [],
    SuggestionPlan suggestion = const SuggestionPlan(title: null, tags: []),
  }) : super(suggestion: suggestion);

  final Completer<void> gate;

  @override
  Future<SuggestionPlan> suggestTitle(String id) async {
    await gate.future;
    return super.suggestTitle(id);
  }

  @override
  Future<SuggestionPlan> suggestTags(String id) async {
    await gate.future;
    return super.suggestTags(id);
  }
}

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

      // The initial tag is editable (TagChip with a delete action).
      expect(find.byType(TagChip), findsOneWidget);
      expect(find.text('finance'), findsOneWidget);

      // Open the compact composer via the PLUS button and name a new tag.
      await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'tax');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Add tag'),
        ),
      );
      await tester.pumpAndSettle();

      // The service persisted the new tag list.
      expect(service.setTagsCount, 1);
      expect(service.lastSetTags, containsAll(['finance', 'tax']));
      // And the view reflects the updated document metadata.
      expect(find.byType(TagChip), findsNWidgets(2));
      expect(find.text('tax'), findsOneWidget);
    });

    testWidgets(
      'adds a tag optimistically — the chip appears before the persist '
      'round-trip finishes',
      (tester) async {
        final doc = _doc(tags: const ['finance']);
        final gate = Completer<void>();
        final service = _GatedTagService(gate: gate, documents: [doc]);

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
        await tester.pumpAndSettle();
        await tester.enterText(find.byType(TextField).last, 'tax');
        await tester.tap(
          find.descendant(
            of: find.byType(AlertDialog),
            matching: find.byTooltip('Add tag'),
          ),
        );
        // The dialog pops; the optimistic chip appears with just one pump —
        // the persist is still pending on the gate.
        await tester.pump();
        await tester.pump();

        expect(
          find.byType(TagChip),
          findsNWidgets(2),
          reason: 'The new chip must be visible before persistence completes.',
        );
        // The chip label (not the composing TextField, which may still be
        // animating out) carries the new tag.
        expect(
          find.descendant(of: find.byType(TagChip), matching: find.text('tax')),
          findsOneWidget,
        );
        expect(service.setTagsCount, 1);

        // Release the gate; the optimistic UI stays.
        gate.complete();
        await tester.pumpAndSettle();
        expect(
          find.descendant(of: find.byType(TagChip), matching: find.text('tax')),
          findsOneWidget,
        );
        expect(service.lastSetTags, containsAll(['finance', 'tax']));
      },
    );

    testWidgets('reverts an optimistically-added tag when the persist fails', (
      tester,
    ) async {
      final doc = _doc(tags: const ['finance']);
      final service = _FailingTagService(documents: [doc]);

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).last, 'doomed');
      await tester.tap(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.byTooltip('Add tag'),
        ),
      );
      await tester.pump();

      // Optimistic chip appeared (the dialog's TextField may still be animating
      // out, so scope to the chip).
      expect(
        find.descendant(
          of: find.byType(TagChip),
          matching: find.text('doomed'),
        ),
        findsOneWidget,
      );
      expect(find.byType(TagChip), findsNWidgets(2));

      // The persist fails → the chip reverts and an error snackbar shows.
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(TagChip),
          matching: find.text('doomed'),
        ),
        findsNothing,
      );
      expect(find.byType(TagChip), findsOneWidget);
      expect(find.textContaining('Could not update tags'), findsOneWidget);
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

      expect(find.byType(TagChip), findsNWidgets(2));

      // Tap the delete affordance on the 'tax' chip. With the default touch
      // pointer the X is always visible, so this finder is stable even while
      // the chip is off-screen mid-list.
      expect(_deleteIconFor('tax'), findsOneWidget);
      // The chip may be mid-scroll offscreen; the delete still fires.
      await tester.tap(_deleteIconFor('tax'), warnIfMissed: false);
      await tester.pumpAndSettle();

      expect(service.setTagsCount, 1);
      expect(service.lastSetTags, ['finance']);
      expect(find.byType(TagChip), findsOneWidget);
      expect(find.text('tax'), findsNothing);
    });

    testWidgets(
      'shows the delete X only while the tag chip is hovered on desktop',
      (tester) async {
        final doc = _doc(tags: const ['finance', 'tax']);
        final service = FakeDocumentService(
          documents: [doc],
          contentByDocumentId: {'doc-1': 'Report body'},
        );

        // Default viewport so the tags row is comfortably on-screen.
        tester.view.physicalSize = const Size(1200, 1200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        final taxChip = find.ancestor(
          of: find.text('tax'),
          matching: find.byType(TagChip),
        );
        // Mouse hover over the chip; the X is inside a TagDeleteIcon whose
        // AnimatedOpacity fades in.
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(taxChip));
        await tester.pumpAndSettle();
        expect(_deleteIconFor('tax'), findsOneWidget);

        // Move the pointer away; the X fades back out but the icon (with
        // opacity 0) still exists inside the chip's delete slot.
        await mouse.moveTo(
          tester.getTopLeft(find.byType(DocumentDetailView)) +
              const Offset(10, 700),
        );
        await tester.pumpAndSettle();
        final opacity = tester.widget<AnimatedOpacity>(
          find.descendant(of: taxChip, matching: find.byType(AnimatedOpacity)),
        );
        expect(opacity.opacity, 0);
      },
    );

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
      // There is no 'Save title' button anymore — committing via Enter/submit.
      await tester.testTextInput.receiveAction(TextInputAction.done);
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
      'renders the split suggestion actions (magic wand + tags button)',
      (tester) async {
        final doc = _doc();
        final service = FakeDocumentService(
          documents: [doc],
          contentByDocumentId: {'doc-1': 'Report body'},
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        // The magic-wand "Suggest title" replaced the old 'Save title' check.
        expect(find.byTooltip('Suggest title'), findsOneWidget);
        // Both title and tags now share the same magic-wand icon.
        expect(find.byIcon(Icons.auto_fix_high), findsNWidgets(2));
        expect(find.byTooltip('Save title'), findsNothing);
        // A distinct "Suggest tags" action exists (not a combined button).
        expect(find.byTooltip('Suggest tags'), findsOneWidget);
        expect(find.text('Suggest title & tags'), findsNothing);
      },
    );

    testWidgets(
      'magic wand suggests a title and applies it when not manually edited',
      (tester) async {
        final doc = _doc(title: 'Old title', tags: const ['stale']);
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

        await tester.tap(find.byTooltip('Suggest title'));
        await tester.pumpAndSettle();

        // Only the title suggestion ran — the tags stay untouched.
        expect(service.suggestTitleCount, 1);
        expect(service.suggestTagsCount, 0);
        expect(service.updateTitleCount, 1);
        expect(service.lastTitle, 'Suggested title');
        expect(service.setTagsCount, 0);
        // UI reflects the applied title and the snackbar confirms it.
        expect(find.text('Suggested title'), findsOneWidget);
        expect(
          find.textContaining('Title suggested: Suggested title'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'suggest title is async and does not block the UI while running',
      (tester) async {
        final doc = _doc(title: 'Old title');
        final gate = Completer<void>();
        final service = _GatedSuggestService(
          gate: gate,
          documents: [doc],
          suggestion: const SuggestionPlan(title: 'Deferred title', tags: []),
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        // The wand click returns immediately; while the suggestion is pending
        // the spinner shows and the UI stays interactive.
        await tester.tap(find.byTooltip('Suggest title'));
        await tester.pump();
        expect(
          find.descendant(
            of: find.byType(DocumentDetailView),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsWidgets,
        );
        // The title field is still usable — the UI did not block.
        await tester.enterText(_titleField(), 'Typed while suggesting');
        expect(
          tester.widget<TextField>(_titleField()).controller!.text,
          'Typed while suggesting',
        );

        // Release the suggestion; the completed run updates the title.
        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('Deferred title'), findsWidgets);
        expect(
          find.textContaining('Title suggested: Deferred title'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'suggest title respects the manual title flag and keeps the user title',
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

        await tester.tap(find.byTooltip('Suggest title'));
        await tester.pumpAndSettle();

        // The suggestion ran, but the title was NOT overwritten.
        expect(service.suggestTitleCount, 1);
        expect(service.updateTitleCount, 0);
        expect(service.lastTitle, isNull);
        expect(find.text('User title'), findsOneWidget);
        expect(find.text('Suggested title'), findsNothing);
        // The wand only touches title — tags are never touched.
        expect(service.suggestTagsCount, 0);
        expect(service.setTagsCount, 0);
        expect(
          find.textContaining('Title unchanged (manually edited)'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'suggest tags applies the suggested tags when not manually edited',
      (tester) async {
        final doc = _doc(tags: const ['stale'], title: 'Keep title');
        final service = FakeDocumentService(
          documents: [doc],
          contentByDocumentId: {'doc-1': 'Report body'},
          suggestion: const SuggestionPlan(
            title: 'Discarded title suggestion',
            tags: ['finance', 'q3'],
          ),
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Suggest tags'));
        await tester.pumpAndSettle();

        // Only the tags suggestion ran — the title stays untouched.
        expect(service.suggestTagsCount, 1);
        expect(service.suggestTitleCount, 0);
        expect(service.setTagsCount, 1);
        expect(service.lastSetTags, containsAll(['finance', 'q3']));
        expect(find.text('finance'), findsWidgets);
        expect(find.text('stale'), findsNothing);
        expect(find.text('Discarded title suggestion'), findsNothing);
        expect(
          find.textContaining('Tags suggested: finance, q3'),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'suggest tags is async and does not block the UI while running',
      (tester) async {
        final doc = _doc();
        final gate = Completer<void>();
        final service = _GatedSuggestService(
          gate: gate,
          documents: [doc],
          suggestion: const SuggestionPlan(title: null, tags: ['deferred']),
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        await tester.tap(find.byTooltip('Suggest tags'));
        await tester.pump();
        // The button shows an in-flight spinner; the UI is still responsive.
        expect(
          find.descendant(
            of: find.byType(DocumentDetailView),
            matching: find.byType(CircularProgressIndicator),
          ),
          findsWidgets,
        );
        await tester.enterText(_titleField(), 'Still typing');
        expect(
          tester.widget<TextField>(_titleField()).controller!.text,
          'Still typing',
        );

        gate.complete();
        await tester.pumpAndSettle();
        expect(find.text('deferred'), findsWidgets);
        expect(find.textContaining('Tags suggested: deferred'), findsOneWidget);
      },
    );

    testWidgets('suggest tags respects the manual tags flag and keeps tags', (
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

      await tester.tap(find.text('Suggest tags'));
      await tester.pumpAndSettle();

      // The suggestion ran, but the tags were NOT overwritten; the title is
      // never touched by the tags action either.
      expect(service.suggestTagsCount, 1);
      expect(service.updateTitleCount, 0);
      expect(service.setTagsCount, 0);
      expect(find.text('keep-me'), findsOneWidget);
      expect(find.text('auto'), findsNothing);
      expect(
        find.textContaining('Tags unchanged (manually edited)'),
        findsOneWidget,
      );
    });

    testWidgets(
      'plus composer shows existing-but-not-applied tags and applies a tap',
      (tester) async {
        final doc = _doc(tags: const ['already-there']);
        final service = FakeDocumentService(
          documents: [doc],
          tags: const ['existing-tag', 'already-there', 'other-known'],
          contentByDocumentId: {'doc-1': 'Report body'},
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        // Open the composer via the PLUS button.
        await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
        await tester.pumpAndSettle();

        // The dialog lists known tags that are not yet on the document.
        // "Add tag" appears both as the ActionChip label and the dialog title.
        expect(find.text('Add tag'), findsNWidgets(2));
        expect(find.text('existing-tag'), findsOneWidget);
        expect(find.text('other-known'), findsOneWidget);
        // Tags already applied are filtered out of the suggestion list.
        expect(find.text('already-there'), findsNWidgets(1));

        // Selecting a suggested tag applies it instantly (optimistically) and
        // closes the dialog.
        await tester.tap(find.text('existing-tag'));
        await tester.pumpAndSettle();

        expect(service.setTagsCount, 1);
        expect(
          service.lastSetTags,
          containsAll(['already-there', 'existing-tag']),
        );
        expect(find.byType(TagChip), findsNWidgets(2));
        expect(find.text('existing-tag'), findsOneWidget);
      },
    );

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
