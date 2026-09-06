import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/features/tag_hierarchy.dart'
    show suggestTagCompletions, validateTagPath, renamedTagsByDoc;
import 'package:docer/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docer/src/ui/widgets.dart' show TagChip;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Seed data matching the task spec.
const _knn = DocumentSummary(
  id: 'knn',
  title: 'knn',
  tags: ['study/lecture', 'study/mit/ml'],
);

const _qsort = DocumentSummary(
  id: 'qsort',
  title: 'qsort',
  tags: ['study/seminar', 'study/mit/cprog'],
);

const _s1 = DocumentSummary(
  id: 's1',
  title: 's1',
  tags: ['seminar'],
);

/// The edit (pencil) affordance on the [TagChip] whose label is [tagLabel].
Finder _editIconFor(String tagLabel) {
  final chip = find.ancestor(
    of: find.text(tagLabel),
    matching: find.byType(TagChip),
  );
  return find.descendant(of: chip, matching: find.byIcon(Icons.edit));
}

void main() {
  group('suggestTagCompletions', () {
    const allTags = [
      'study/lecture',
      'study/mit/ml',
      'study/mit/machine-learning',
      'study/seminar',
      'study/mit/cprog',
    ];

    test('exact match returns first', () {
      final r = suggestTagCompletions('seminar', allTags);
      expect(r.first, 'study/seminar');
    });

    test('full prefix matches', () {
      final r = suggestTagCompletions('study', allTags);
      expect(r, contains('study/lecture'));
    });

    test('segment prefix matches machine-learning', () {
      final r = suggestTagCompletions('machine-le', allTags);
      expect(r, contains('study/mit/machine-learning'));
    });

    test('subsequence smitml matches machine-learning', () {
      final r = suggestTagCompletions('smitml', allTags);
      expect(r, contains('study/mit/machine-learning'));
    });

    test('empty query returns empty list', () {
      expect(suggestTagCompletions('', allTags), isEmpty);
    });

    test('limit is respected', () {
      final r = suggestTagCompletions('study', allTags, limit: 2);
      expect(r.length, 2);
    });

    test('case-insensitive', () {
      final r = suggestTagCompletions('SEMINAR', allTags);
      expect(r.first, 'study/seminar');
    });
  });

  group('validateTagPath', () {
    test('valid tag returns null', () {
      expect(validateTagPath('study/mit/machine-learning'), isNull);
      expect(validateTagPath('seminar'), isNull);
    });

    test('empty tag returns error', () {
      expect(validateTagPath(''), isNotNull);
    });

    test('leading slash returns error', () {
      expect(validateTagPath('/foo'), isNotNull);
    });

    test('trailing slash returns error', () {
      expect(validateTagPath('foo/'), isNotNull);
    });

    test('empty segment returns error', () {
      expect(validateTagPath('a//b'), isNotNull);
    });

    test('whitespace in segment is allowed (space is in the charset)', () {
      expect(validateTagPath('a/b c'), isNull);
    });
  });

  group('renamedTagsByDoc', () {
    test('renames exact oldPath only', () {
      final tagsByDoc = {
        'doc1': {'seminar'},
        'doc2': {'study/seminar', 'math'},
      };
      final changed = renamedTagsByDoc(tagsByDoc, 'seminar', 'mit/seminar');
      // doc1 had 'seminar' → changed
      expect(changed.containsKey('doc1'), isTrue);
      expect(changed['doc1'], contains('mit/seminar'));
      expect(changed['doc1'], isNot(contains('seminar')));
      // doc2 has 'study/seminar' (not exact 'seminar') → unchanged
      expect(changed.containsKey('doc2'), isFalse);
    });

    test('same old/new returns empty map', () {
      final tagsByDoc = {
        'doc1': {'seminar'},
      };
      expect(renamedTagsByDoc(tagsByDoc, 'seminar', 'seminar'), isEmpty);
    });

    test('preserves order and dedupes', () {
      final tagsByDoc = {
        'doc1': {'a', 'seminar', 'b'},
      };
      final changed = renamedTagsByDoc(tagsByDoc, 'seminar', 'c');
      expect(changed['doc1']!.toList(), ['a', 'c', 'b']);
    });

    test('newPath already present dedupes', () {
      final tagsByDoc = {
        'doc1': {'a', 'seminar', 'b'},
      };
      final changed = renamedTagsByDoc(tagsByDoc, 'seminar', 'a');
      // 'a' was already present; 'seminar' is replaced with 'a', deduped
      expect(changed['doc1']!.toList(), ['a', 'b']);
    });
  });

  group('DocumentDetailView rename tag', () {
    testWidgets('rename seminar → mit/seminar across documents', (tester) async {
      final docs = [
        _knn,
        _qsort,
        _s1,
      ];
      final service = FakeDocumentService(documents: docs);

      await tester.pumpWidget(
        _wrap(DocumentDetailView(
          document: _s1,
          documentService: service,
        )),
      );
      await tester.pumpAndSettle();

      // The 'seminar' chip is visible with an edit icon.
      expect(find.text('seminar'), findsOneWidget);
      expect(_editIconFor('seminar'), findsOneWidget);

      // Tap the edit icon.
      await tester.tap(_editIconFor('seminar'));
      await tester.pumpAndSettle();

      // Dialog appears.
      expect(find.byKey(const ValueKey('rename-tag-dialog')), findsOneWidget);

      // Field is prefilled with 'seminar'.
      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('rename-tag-field')),
      );
      expect(field.controller!.text, 'seminar');

      // Info line shows 'Used by 1 document'.
      expect(find.textContaining('1 document'), findsOneWidget);

      // Change to 'mit/seminar'.
      await tester.enterText(
        find.byKey(const ValueKey('rename-tag-field')),
        'mit/seminar',
      );
      await tester.tap(find.byKey(const ValueKey('rename-tag-save')));
      await tester.pumpAndSettle();

      // Snackbar says '1 document'.
      expect(find.textContaining('1 document'), findsOneWidget);

      // s1 now has 'mit/seminar'.
      final s1After = await service.getDocument('s1');
      expect(s1After.tags, contains('mit/seminar'));
      expect(s1After.tags, isNot(contains('seminar')));

      // knn and qsort are untouched.
      final knnAfter = await service.getDocument('knn');
      expect(knnAfter.tags, containsAll(['study/lecture', 'study/mit/ml']));
      final qsortAfter = await service.getDocument('qsort');
      expect(qsortAfter.tags, containsAll(['study/seminar', 'study/mit/cprog']));
    });

    testWidgets('no documents use tag shows message', (tester) async {
      final docs = [
        _knn,
        _qsort,
        const DocumentSummary(id: 'empty', title: 'empty', tags: []),
      ];
      final service = FakeDocumentService(documents: docs);

      await tester.pumpWidget(
        _wrap(DocumentDetailView(
          document: _knn,
          documentService: service,
        )),
      );
      await tester.pumpAndSettle();

      // Tap edit on 'study/lecture'.
      await tester.tap(_editIconFor('study/lecture'));
      await tester.pumpAndSettle();

      // Rename to 'nonexistent-old' (rename something no one else has).
      // Wait — 'study/lecture' IS on knn. Let's test the path: rename
      // knn's 'study/lecture' to 'study/lecture-v2'.  knn should change,
      // the snackbar should show '1 document'.
      await tester.enterText(
        find.byKey(const ValueKey('rename-tag-field')),
        'study/lecture-v2',
      );
      await tester.tap(find.byKey(const ValueKey('rename-tag-save')));
      await tester.pumpAndSettle();

      expect(find.textContaining('1 document'), findsOneWidget);

      final knnAfter = await service.getDocument('knn');
      expect(knnAfter.tags, contains('study/lecture-v2'));
      expect(knnAfter.tags, isNot(contains('study/lecture')));
    });
  });

  group('DocumentDetailView composer suggestions', () {
    testWidgets(
      'typing machine-le shows study/mit/machine-learning suggestion',
      (tester) async {
        final docs = [_knn, _qsort, _s1];
        final service = FakeDocumentService(
          documents: docs,
          tags: [
            'study/lecture',
            'study/mit/ml',
            'study/mit/machine-learning',
            'study/seminar',
            'study/mit/cprog',
          ],
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(
            document: _s1,
            documentService: service,
          )),
        );
        await tester.pumpAndSettle();

        // Open the add-tag composer.
        await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
        await tester.pumpAndSettle();

        // Type 'machine-le'.
        await tester.enterText(
          find.byKey(const ValueKey('add-tag-field')),
          'machine-le',
        );
        await tester.pump();

        // The suggestion chip appears.
        expect(
          find.byKey(
            const ValueKey('tag-suggestion-study/mit/machine-learning'),
          ),
          findsOneWidget,
        );

        // Tap the suggestion → fills the field.
        await tester.tap(
          find.byKey(
            const ValueKey('tag-suggestion-study/mit/machine-learning'),
          ),
        );
        await tester.pump();

        final filled = tester.widget<TextField>(
          find.byKey(const ValueKey('add-tag-field')),
        );
        expect(filled.controller!.text, 'study/mit/machine-learning');
      },
    );

    testWidgets('typing smitml shows same suggestion via subsequence', (
      tester,
    ) async {
      final docs = [_knn, _qsort, _s1];
      final service = FakeDocumentService(
        documents: docs,
        tags: [
          'study/lecture',
          'study/mit/ml',
          'study/mit/machine-learning',
          'study/seminar',
          'study/mit/cprog',
        ],
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(
          document: _s1,
          documentService: service,
        )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('add-tag-field')),
        'smitml',
      );
      await tester.pump();

      // Both machine-learning and ml match via subsequence;
      // machine-learning must be present.
      expect(
        find.byKey(
          const ValueKey('tag-suggestion-study/mit/machine-learning'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('brand-new tag + Enter creates it', (tester) async {
      final docs = [_knn, _qsort, _s1];
      final service = FakeDocumentService(
        documents: docs,
        tags: [
          'study/lecture',
          'study/mit/ml',
          'study/mit/machine-learning',
          'study/seminar',
          'study/mit/cprog',
        ],
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(
          document: _s1,
          documentService: service,
        )),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byTooltip('Add tag'), warnIfMissed: false);
      await tester.pumpAndSettle();

      // Type an unmatched name + Enter.
      await tester.enterText(
        find.byKey(const ValueKey('add-tag-field')),
        'brandnew',
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();

      // The service persisted the new tag.
      expect(service.setTagsCount, 1);
      expect(service.lastSetTags, contains('brandnew'));

      // The view updated: s1 now has 2 tags.
      final s1After = await service.getDocument('s1');
      expect(s1After.tags, contains('brandnew'));
    });
  });

  group('DocumentsScreen bulk dialog suggestions', () {
    testWidgets(
      'bulk add tag dialog shows fuzzy suggestions and fills field',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            const DocumentSummary(
              id: 'b1',
              title: 'b1',
              tags: ['study/mit/machine-learning'],
            ),
            _qsort,
          ],
          tags: [
            'study/lecture',
            'study/mit/ml',
            'study/mit/machine-learning',
            'study/seminar',
            'study/mit/cprog',
          ],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
          ),
        );
        await tester.pumpAndSettle();

        // Enter selection mode.
        await tester.tap(find.byKey(const ValueKey('select-documents')));
        await tester.pumpAndSettle();
        expect(find.text('2 selected'), findsOneWidget);

        // Tap bulk add tag.
        await tester.tap(find.byKey(const ValueKey('bulk-add-tag')));
        await tester.pumpAndSettle();

        // Type 'machine-le'.
        await tester.enterText(
          find.byKey(const ValueKey('tag-name-field')),
          'machine-le',
        );
        await tester.pump();

        // The suggestion section and chip appear.
        expect(find.byKey(const ValueKey('tag-suggestions-bulk')), findsOneWidget);
        expect(
          find.byKey(
            const ValueKey('tag-suggestion-study/mit/machine-learning'),
          ),
          findsOneWidget,
        );

        // Tap the suggestion → fills the field.
        await tester.tap(
          find.byKey(
            const ValueKey('tag-suggestion-study/mit/machine-learning'),
          ),
        );
        await tester.pump();

        final filled = tester.widget<TextField>(
          find.byKey(const ValueKey('tag-name-field')),
        );
        expect(filled.controller!.text, 'study/mit/machine-learning');
      },
    );
  });
}
