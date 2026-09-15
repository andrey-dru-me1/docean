import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:super_drag_and_drop/super_drag_and_drop.dart'
    show DragItemWidget;

import 'package:docean/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docean/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;
import 'package:docean/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docean/src/ui/tag_hierarchy_view.dart' show TagHierarchyView;
import 'package:docean/src/ui/widgets.dart' show TagChip, tagColorFor;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

DocumentSummary _doc(String id, String title, {List<String> tags = const []}) =>
    DocumentSummary(id: id, title: title, tags: tags);

/// The standard fixture used across tree-structure tests.
///
/// knn[study/lecture, study/mit/ml]
/// qsort[study/seminar, study/mit/cprog]
/// notes[idea]   (plain top-level leaf)
/// memo[todo]    (plain top-level leaf)
FakeDocumentService _treeService({
  bool withNestedFiles = false,
  bool withRootFile = false,
  bool withUniform = false,
}) => FakeDocumentService(
  documents: [
    _doc('knn', 'KNN notes', tags: const ['study/lecture', 'study/mit/ml']),
    _doc(
      'qsort',
      'Qsort impl',
      tags: const ['study/seminar', 'study/mit/cprog'],
    ),
    _doc('notes', 'Ideas', tags: const ['idea']),
    _doc('memo', 'TODOs', tags: const ['todo']),
    if (withNestedFiles)
      _doc('mit-notes', 'MIT notes', tags: const ['study/mit']),
    if (withRootFile) _doc('study-doc', 'Study doc', tags: const ['study']),
    if (withUniform) _doc('deep', 'Deep doc', tags: const ['a/b/c']),
  ],
  tags: const [
    'study/lecture',
    'study/mit/ml',
    'study/seminar',
    'study/mit/cprog',
    'idea',
    'todo',
  ],
);

Future<void> _toggleToTags(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.account_tree));
  await tester.pumpAndSettle();
}

String nodeKey(List<String> comps) => 'tag-node-${comps.join('\u0000')}';

String docRowKey(String id, List<String> comps) =>
    'tag-doc-$id@${comps.join('\u0000')}';

/// Document row key for a file of the root / current (filtered) directory.
String fileRowKey(String id) => 'tag-doc-$id@';

/// Taps a tag row by its walk, scrolling it into view first — deep lattice
/// walks extend past the viewport and ListView lazily builds rows.
Future<void> _tapNode(WidgetTester tester, List<String> components) async {
  final finder = find.byKey(ValueKey(nodeKey(components)));
  // Lazy ListView: rows are built on demand, so drag manually until the row
  // enters the tree (dragUntilVisible throws if the finder never resolves).
  for (var i = 0; i < 60 && finder.evaluate().isEmpty; i++) {
    await tester.drag(find.byType(ListView).first, const Offset(0, -120));
    await tester.pumpAndSettle();
  }
  await tester.tap(finder, warnIfMissed: false);
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------
  // Own colors: tagColorFor hashes the full path, not just top-level
  // ---------------------------------------------------------------
  group('own colors', () {
    test(
      'tagColorFor produces distinct colors for each hierarchical level',
      () {
        expect(tagColorFor('study'), isNot(equals(tagColorFor('study/mit'))));
        expect(
          tagColorFor('study/mit'),
          isNot(equals(tagColorFor('study/mit/ml'))),
        );
        expect(
          tagColorFor('study'),
          isNot(equals(tagColorFor('study/mit/ml'))),
        );
      },
    );
  });

  // ---------------------------------------------------------------
  // Split pill (TagChip)
  // ---------------------------------------------------------------
  group('split pill', () {
    testWidgets(
      'pumping TagChip(label: study/mit/ml) renders 3 colored segments '
      'and 2 dividers',
      (tester) async {
        await tester.pumpWidget(_wrap(const TagChip(label: 'study/mit/ml')));

        // Three text widgets, one per segment.
        expect(find.text('study'), findsOneWidget);
        expect(find.text('mit'), findsOneWidget);
        expect(find.text('ml'), findsOneWidget);

        // Each segment's block Container has its own cumulative-prefix color.
        Color blockColor(String segment) {
          final container = tester.widget<Container>(
            find
                .ancestor(
                  of: find.text(segment),
                  matching: find.byType(Container),
                )
                .first,
          );
          return container.color!;
        }

        final studyColor = blockColor('study');
        final mitColor = blockColor('mit');
        final mlColor = blockColor('ml');

        expect(studyColor, tagColorFor('study'));
        expect(mitColor, tagColorFor('study/mit'));
        expect(mlColor, tagColorFor('study/mit/ml'));

        // All three are distinct.
        expect(studyColor, isNot(equals(mitColor)));
        expect(mitColor, isNot(equals(mlColor)));

        // Two 1px white24 dividers between the three blocks.
        expect(
          find.descendant(
            of: find.byType(TagChip),
            matching: find.byWidgetPredicate(
              (w) => w is ColoredBox && w.color == Colors.white24,
            ),
          ),
          findsNWidgets(2),
        );
      },
    );

    testWidgets('split pill selected state lightens every segment color', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const TagChip(label: 'study/mit/ml', selected: true)),
      );

      Color blockColor(String segment) {
        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.text(segment),
                matching: find.byType(Container),
              )
              .first,
        );
        return container.color!;
      }

      expect(
        blockColor('study'),
        Color.lerp(tagColorFor('study'), Colors.white, 0.38)!,
      );
      expect(
        blockColor('mit'),
        Color.lerp(tagColorFor('study/mit'), Colors.white, 0.38)!,
      );
      expect(
        blockColor('ml'),
        Color.lerp(tagColorFor('study/mit/ml'), Colors.white, 0.38)!,
      );
    });
  });

  // ---------------------------------------------------------------
  // Tag hierarchy tree view
  // ---------------------------------------------------------------
  group('TagHierarchyView tree', () {
    testWidgets('shows top-level study with count badge 2', (tester) async {
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      expect(find.byKey(ValueKey(nodeKey(['study']))), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(ValueKey(nodeKey(['study']))),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
    });

    testWidgets(
      'study absorbs equal-count mit; grandchildren become children',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: _treeService(),
              onOpenDocument: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();

        // mit carries the same 2 docs as study -> absorbed into its row.
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
          findsNothing,
        );
        // The pre-absorption sibling keys are gone entirely.
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/lecture']))),
          findsNothing,
        );
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/seminar']))),
          findsNothing,
        );
        // All four grandchildren surface under the merged row, grouped:
        // mit's children (cprog, ml - alpha) first, then study's
        // (lecture, seminar).
        final cprog = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog'])),
        );
        final ml = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/mit/ml'])),
        );
        final lecture = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/lecture'])),
        );
        final seminar = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/seminar'])),
        );
        for (final f in [cprog, ml, lecture, seminar]) {
          expect(f, findsOneWidget);
        }
        expect(tester.getTopLeft(cprog).dy, lessThan(tester.getTopLeft(ml).dy));
        expect(
          tester.getTopLeft(ml).dy,
          lessThan(tester.getTopLeft(lecture).dy),
        );
        expect(
          tester.getTopLeft(lecture).dy,
          lessThan(tester.getTopLeft(seminar).dy),
        );
        // 'study, mit (2)': the absorbed tag shows in the row text, the
        // badge keeps the merged document count.
        final studyRow = find.byKey(ValueKey(nodeKey(['study'])));
        expect(
          find.descendant(of: studyRow, matching: find.textContaining('mit')),
          findsOneWidget,
        );
        expect(
          find.descendant(of: studyRow, matching: find.text('2')),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'mixed paths reach every document: qsort via cprog, knn via ml',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1800);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: _treeService(),
              onOpenDocument: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        // study absorbs mit; drill into cprog - it absorbs qsort's other
        // tag (seminar) because alone it holds the single doc there.
        await _tapNode(tester, ['study']);
        await _tapNode(tester, ['study', 'study/mit', 'study/mit/cprog']);
        final cprogRow = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog'])),
        );
        expect(
          find.descendant(
            of: cprogRow,
            matching: find.textContaining('seminar'),
          ),
          findsOneWidget,
        );
        expect(
          find.byKey(
            ValueKey(
              docRowKey('qsort', ['study', 'study/mit', 'study/mit/cprog']),
            ),
          ),
          findsOneWidget,
        );
        // No standalone directory row for the absorbed seminar tail.
        expect(
          find.byKey(
            ValueKey(
              nodeKey([
                'study',
                'study/mit',
                'study/mit/cprog',
                'study/seminar',
              ]),
            ),
          ),
          findsNothing,
        );

        // A pill keyed tag-parent-pill-study-<run> exists (study-group rows).
        final studyPills = find.byWidgetPredicate(
          (w) =>
              w.key is ValueKey<String> &&
              (w.key as ValueKey<String>).value.startsWith(
                'tag-parent-pill-study-',
              ),
        );
        expect(studyPills, findsWidgets);

        // knn symmetric: ml absorbs lecture.
        await _tapNode(tester, ['study', 'study/mit', 'study/mit/ml']);
        expect(
          find.byKey(
            ValueKey(docRowKey('knn', ['study', 'study/mit', 'study/mit/ml'])),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'files: root directory defers below sections, nested files stay in place',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: _treeService(
                withNestedFiles: true,
                withRootFile: true,
              ),
              onOpenDocument: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))));
        await tester.pumpAndSettle();

        // mit's own file: inside mit's container, after its child rows.
        final mitNotes = tester.getTopLeft(
          find.byKey(ValueKey(docRowKey('mit-notes', ['study', 'study/mit']))),
        );
        final cprog = tester.getTopLeft(
          find.byKey(
            ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog'])),
          ),
        );
        final seminarMit = tester.getTopLeft(
          find.byKey(
            ValueKey(nodeKey(['study', 'study/mit', 'study/seminar'])),
          ),
        );
        expect(cprog.dy, lessThan(mitNotes.dy));
        expect(seminarMit.dy, lessThan(mitNotes.dy));

        // Root directory file: inside study's container, after its group
        // rows (which follow mit's nested container).
        final studyDoc = tester.getTopLeft(
          find.byKey(ValueKey(docRowKey('study-doc', ['study']))),
        );
        expect(mitNotes.dy, lessThan(studyDoc.dy));
        final lecture = tester.getTopLeft(
          find.byKey(ValueKey(nodeKey(['study', 'study/lecture']))),
        );
        expect(lecture.dy, lessThan(studyDoc.dy));
      },
    );

    testWidgets('uniform deep path collapses to one row with remaining tags', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _treeService(withUniform: true),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      // 'a' contains only doc 'deep' (set a, a/b, a/b/c) → uniform:
      // the collapsed row lists the remaining tags b, c; NO child
      // directory rows for a/b or a/b/c exist.
      final aRow = find.byKey(ValueKey(nodeKey(['a'])));
      expect(aRow, findsOneWidget);
      expect(
        find.descendant(of: aRow, matching: find.textContaining('a, b, c')),
        findsOneWidget,
      );
      expect(find.byKey(ValueKey(nodeKey(['a', 'a/b']))), findsNothing);

      // Expanding the collapsed row lists the document links directly.
      await tester.tap(aRow);
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(docRowKey('deep', ['a']))), findsOneWidget);
    });

    testWidgets('collapse study after expanding ml preserves expanded state', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
      await tester.pumpAndSettle();
      final mlRow = find.byKey(
        ValueKey(nodeKey(['study', 'study/mit', 'study/mit/ml'])),
      );
      expect(mlRow, findsOneWidget);

      await tester.tap(mlRow);
      await tester.pumpAndSettle();
      final knnDoc = find.byKey(
        ValueKey(docRowKey('knn', ['study', 'study/mit', 'study/mit/ml'])),
      );
      expect(knnDoc, findsOneWidget);

      // Collapse study - no exception; children disappear.
      await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
      await tester.pumpAndSettle();
      expect(mlRow, findsNothing);

      // Re-expand study - ml is still expanded.
      await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
      await tester.pumpAndSettle();
      expect(knnDoc, findsOneWidget);
    });

    testWidgets('tag-tree-toggle-all expands and collapses all', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1200, 1800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      expect(
        find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
        findsNothing,
      );
      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();

      // Both documents reachable — their uniform subtrees collapse at the
      // ml/cprog level (each is the single contained doc below it).
      expect(
        find.byKey(
          ValueKey(docRowKey('knn', ['study', 'study/mit', 'study/mit/ml'])),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(
          ValueKey(
            docRowKey('qsort', ['study', 'study/mit', 'study/mit/cprog']),
          ),
        ),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
        findsNothing,
      );
    });

    testWidgets(
      'tree rows render colorful Text.rich path and contain no TagChip',
      (tester) async {
        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: _treeService(),
              onOpenDocument: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();

        // The merged 'study, mit' row shows its colorful path spans.
        expect(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(['study']))),
            matching: find.textContaining('mit'),
          ),
          findsOneWidget,
        );

        // No TagChip inside the tree (pills are replaced by text).
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-hierarchy-view')),
            matching: find.byType(TagChip),
          ),
          findsNothing,
        );

        // study/mit row's gutter: the spanning rotated pill for 'study'.
        expect(
          find.byWidgetPredicate(
            (w) =>
                w.key is ValueKey<String> &&
                (w.key as ValueKey<String>).value.startsWith(
                  'tag-parent-pill-study-',
                ),
          ),
          findsWidgets,
        );
      },
    );
  });

  // ---------------------------------------------------------------
  // Ancestor swallowing in document views
  // ---------------------------------------------------------------
  group('ancestor swallowing', () {
    testWidgets(
      'detail view: doc with [study, study/mit, study/mit/ml, student:Alice] '
      'shows exactly 2 TagChips (split pill + property tag)',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc(
              'd1',
              'Deep doc',
              tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
            ),
          ],
          tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
        );

        final doc = _doc(
          'd1',
          'Deep doc',
          tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
        );

        await tester.pumpWidget(
          _wrap(DocumentDetailView(document: doc, documentService: service)),
        );
        await tester.pumpAndSettle();

        // maximalTags reduces to [student:Alice, study/mit/ml] → 2 TagChips.
        expect(find.byType(TagChip), findsNWidgets(2));
        // The split pill renders 'study', 'mit', 'ml' as segment texts inside it.
        expect(find.text('student:Alice'), findsOneWidget);
      },
    );

    testWidgets(
      'grid tile: doc with [study, study/mit, study/mit/ml, student:Alice] '
      'shows exactly 2 TagChips in the tile overlay',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc(
              'd1',
              'Deep doc',
              tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
            ),
          ],
          tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
          ),
        );
        await tester.pumpAndSettle();

        // The tile overlay in the grid shows maximalTags → 2 TagChips.
        // Find TagChips inside GridView tiles (not the filter bar — filter bar
        // uses the same TagChip type but with ValueKey 'filter-*').
        final tileChips = find.descendant(
          of: find.byType(GridView),
          matching: find.byType(TagChip),
        );
        expect(tileChips, findsNWidgets(2));
      },
    );
  });

  // ---------------------------------------------------------------
  // Drag-out of document rows (source only; never drop targets)
  // ---------------------------------------------------------------
  group('drag-out', () {
    testWidgets('document rows are drag sources; tag rows are not', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
      await tester.pumpAndSettle();
      await _tapNode(tester, ['study', 'study/mit', 'study/mit/ml']);

      final docRow = find.byKey(
        ValueKey(docRowKey('knn', ['study', 'study/mit', 'study/mit/ml'])),
      );
      expect(docRow, findsOneWidget);
      // The drag wrapper sits OUTSIDE the row (it wraps it).
      expect(
        find.ancestor(of: docRow, matching: find.byType(DragItemWidget)),
        findsOneWidget,
      );
      expect(
        find.ancestor(
          of: find.byKey(ValueKey(nodeKey(['study']))),
          matching: find.byType(DragItemWidget),
        ),
        findsNothing,
      );
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('no drag wrapper when readBytes is not provided', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: _treeService().documents,
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
      await tester.pumpAndSettle();
      await _tapNode(tester, ['study', 'study/mit', 'study/mit/ml']);
      expect(
        find.byKey(
          ValueKey(docRowKey('knn', ['study', 'study/mit', 'study/mit/ml'])),
        ),
        findsOneWidget,
      );
      expect(find.byType(DragItemWidget), findsNothing);
      debugDefaultTargetPlatformOverride = null;
    });
  });

  // ---------------------------------------------------------------
  // Filtering by a tag moves INTO that directory
  // ---------------------------------------------------------------
  group('filtered tree (cd)', () {
    testWidgets('selected tag row disappears; children re-base to root', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc('mitml', 'MIT ML', tags: const ['mit', 'mit/ml']),
              _doc('mitonly', 'MIT only', tags: const ['mit']),
            ],
            onOpenDocument: (_) {},
            selectedTags: const {'mit'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Inside 'mit': the directory itself is not listed, its child is
      // re-based to root, and the doc that ONLY had 'mit' is a plain file.
      expect(find.byKey(ValueKey(nodeKey(['mit']))), findsNothing);
      expect(find.byKey(ValueKey(nodeKey(['ml']))), findsOneWidget);
      expect(find.byKey(ValueKey(fileRowKey('mitonly'))), findsOneWidget);

      await _tapNode(tester, ['ml']);
      expect(find.byKey(ValueKey(docRowKey('mitml', ['ml']))), findsOneWidget);
    });

    testWidgets('sibling directories of the selection re-base to root', (
      tester,
    ) async {
      // mit/ml selected inside mit: diploma hangs off the hidden 'mit'
      // breadcrumb and must surface as a root 'diploma' directory, never
      // re-materializing an empty 'mit' ghost.
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc(
                'both',
                'ML + diploma thesis',
                tags: const ['mit', 'mit/ml', 'mit/diploma'],
              ),
            ],
            onOpenDocument: (_) {},
            selectedTags: const {'mit/ml'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(nodeKey(['mit']))), findsNothing);
      expect(find.byKey(ValueKey(nodeKey(['ml']))), findsNothing);
      expect(find.byKey(ValueKey(nodeKey(['diploma']))), findsOneWidget);
      // Sibling content remains: NOT a plain file of the current dir.
      expect(find.byKey(ValueKey(fileRowKey('both'))), findsNothing);

      await _tapNode(tester, ['diploma']);
      expect(
        find.byKey(ValueKey(docRowKey('both', ['diploma']))),
        findsOneWidget,
      );
    });

    testWidgets('breadcrumbs above the selected directory are hidden', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc(
                'deep',
                'Deep doc',
                tags: const ['study', 'study/mit', 'study/mit/ml'],
              ),
            ],
            onOpenDocument: (_) {},
            selectedTags: const {'study/mit'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(nodeKey(['study']))), findsNothing);
      expect(
        find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
        findsNothing,
      );
      expect(find.byKey(ValueKey(nodeKey(['ml']))), findsOneWidget);
    });

    testWidgets('multi-select is ONE dir: other tags first, exact docs last', (
      tester,
    ) async {
      // mit/ml + mit/diploma selected: the display equals what expanding
      // those tag dirs shows — remaining ('other') tag dirs FIRST, and at
      // the end the documents that carry exactly the selected tags.
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc(
                'exact',
                'Exactly the two tags',
                tags: const ['mit', 'mit/ml', 'mit/diploma'],
              ),
              _doc(
                'wider',
                'Also has another tag',
                tags: const ['mit', 'mit/ml', 'mit/diploma', 'misc'],
              ),
            ],
            onOpenDocument: (_) {},
            selectedTags: const {'mit/ml', 'mit/diploma'},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Selected dirs vanish entirely (no ghost rows)...
      expect(find.byKey(ValueKey(nodeKey(['ml']))), findsNothing);
      expect(find.byKey(ValueKey(nodeKey(['diploma']))), findsNothing);
      expect(find.byKey(ValueKey(nodeKey(['mit']))), findsNothing);
      // ...the other tag renders as a directory first...
      expect(find.byKey(ValueKey(nodeKey(['misc']))), findsOneWidget);
      // ...and the exact-match document is a file row at the end.
      final misc = find.byKey(ValueKey(nodeKey(['misc'])));
      final file = find.byKey(ValueKey(fileRowKey('exact')));
      expect(file, findsOneWidget);
      expect(
        tester.getTopLeft(misc).dy,
        lessThan(tester.getTopLeft(file).dy),
        reason: 'directories before files',
      );
      expect(
        find.byKey(ValueKey(fileRowKey('wider'))),
        findsNothing,
        reason: 'wider has remaining content: dir member, not a file',
      );

      await _tapNode(tester, ['misc']);
      expect(
        find.byKey(ValueKey(docRowKey('wider', ['misc']))),
        findsOneWidget,
      );
    });

    testWidgets(
      'sibling of selection stays a dir and contains its docs on expand',
      (tester) async {
        // Literal report scenario: doc{nsu/maga, nsu/vkr, kalman_filter}
        // (materialized nsu) filtered by nsu/vkr + nsu/kalman_filter.
        // 'kalman_filter' is the UNRELATED tag kept as a dir; expanding it
        // must show the doc NESTED, never as a top-level row.
        await tester.pumpWidget(
          _wrap(
            TagHierarchyView(
              documents: [
                _doc(
                  'thesis',
                  'Kalman thesis',
                  tags: const ['nsu', 'nsu/maga', 'nsu/vkr', 'kalman_filter'],
                ),
              ],
              onOpenDocument: (_) {},
              selectedTags: const {'nsu/vkr', 'nsu/kalman_filter'},
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(nodeKey(['kalman_filter']))),
          findsOneWidget,
        );
        await _tapNode(tester, ['kalman_filter']);
        final docRow = find.byKey(
          ValueKey(docRowKey('thesis', ['kalman_filter'])),
        );
        expect(docRow, findsOneWidget);
        expect(
          find.byKey(ValueKey('tag-doc-thesis@')),
          findsNothing,
          reason: 'doc with remaining tags must not be a root file',
        );
        // NESTED: strictly indented under the directory row.
        expect(
          tester.getTopLeft(docRow).dx,
          greaterThan(
            tester
                .getTopLeft(find.byKey(ValueKey(nodeKey(['kalman_filter']))))
                .dx,
          ),
          reason: 'expanded doc must be indented under its dir',
        );
      },
    );

    testWidgets('root dir with mixed members still indents its direct docs', (
      tester,
    ) async {
      // Non-uniform expansion: one doc's set EXACTLY equals the dir walk,
      // another continues deeper (kalman_filter/ekf). The exact-match doc
      // used to be deferred OUT of the container (flush at top level);
      // it must now sit indented inside like any nested member.
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc(
                'thesis',
                'Kalman thesis',
                tags: const ['nsu', 'nsu/maga', 'nsu/vkr', 'kalman_filter'],
              ),
              _doc(
                'ekf',
                'EKF extensions',
                tags: const [
                  'nsu',
                  'nsu/maga',
                  'nsu/vkr',
                  'kalman_filter',
                  'kalman_filter/ekf',
                ],
              ),
            ],
            onOpenDocument: (_) {},
            selectedTags: const {'nsu/maga', 'nsu/vkr'},
          ),
        ),
      );
      await tester.pumpAndSettle();
      final dir = find.byKey(ValueKey(nodeKey(['kalman_filter'])));
      expect(dir, findsOneWidget);
      // 'ekf' dir listed too (child of the kept tag).
      await _tapNode(tester, ['kalman_filter']);
      final thesisRow = find.byKey(
        ValueKey(docRowKey('thesis', ['kalman_filter'])),
      );
      expect(thesisRow, findsOneWidget);
      expect(
        tester.getTopLeft(thesisRow).dx,
        greaterThan(tester.getTopLeft(dir).dx),
        reason: 'direct doc of an expanded root dir must be indented',
      );
      expect(
        find.byKey(ValueKey(docRowKey('ekf', ['kalman_filter']))),
        findsNothing,
        reason: 'deeper doc belongs under ekf, not at this level',
      );
    });

    testWidgets('untagged documents are file rows of the root', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TagHierarchyView(
            documents: [
              _doc('tagged', 'Tagged', tags: const ['idea']),
              _doc('bare', 'No tags at all', tags: const []),
              _doc('prop', 'Property only', tags: const ['student:Alice']),
            ],
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(nodeKey(['idea']))), findsOneWidget);
      // The root directory lists its plain files, too.
      expect(find.byKey(ValueKey(fileRowKey('bare'))), findsOneWidget);
      expect(find.byKey(ValueKey(fileRowKey('prop'))), findsOneWidget);
    });
  });
}
