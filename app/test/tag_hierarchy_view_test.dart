import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docean/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;
import 'package:docean/src/ui/documents_screen.dart' show DocumentsScreen;
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
      'study children: mit first (2 remaining docs), then lecture, seminar',
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

        final ys = [
          tester
              .getTopLeft(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))))
              .dy,
          tester
              .getTopLeft(
                find.byKey(ValueKey(nodeKey(['study', 'study/lecture']))),
              )
              .dy,
          tester
              .getTopLeft(
                find.byKey(ValueKey(nodeKey(['study', 'study/seminar']))),
              )
              .dy,
        ];
        for (var i = 0; i < ys.length - 1; i++) {
          expect(ys[i], lessThan(ys[i + 1]));
        }
        // No level-skipping: study/mit/ml (and every tag whose parent chain
        // is not fully walked) must not be listed under study.
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit/ml']))),
          findsNothing,
        );
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit/cprog']))),
          findsNothing,
        );
      },
    );

    testWidgets(
      'expanding mit keeps its siblings, grouped by parent (cprog, ml, lecture, seminar)',
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
        await tester.tap(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))));
        await tester.pumpAndSettle();

        // All four children of the mit walk are visible. Children are FULL
        // tag names (childTags returns tags, not bare segments).
        final cprog = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog'])),
        );
        final ml = find.byKey(
          ValueKey(nodeKey(['study', 'study/mit', 'study/mit/ml'])),
        );
        final lecture = find.byKey(
          ValueKey(nodeKey(['study', 'study/lecture'])),
        );
        final seminar = find.byKey(
          ValueKey(nodeKey(['study', 'study/seminar'])),
        );
        for (final f in [cprog, ml, lecture, seminar]) {
          expect(f, findsOneWidget);
        }
        // Grouped by parent: children of the LAST path tag (mit) first
        // (cprog, ml — alpha within the group), then children of earlier
        // path tags (study): lecture, seminar.
        expect(tester.getTopLeft(cprog).dy, lessThan(tester.getTopLeft(ml).dy));
        expect(
          tester.getTopLeft(ml).dy,
          lessThan(tester.getTopLeft(lecture).dy),
        );
        expect(
          tester.getTopLeft(lecture).dy,
          lessThan(tester.getTopLeft(seminar).dy),
        );
        // mit's children sit deeper than mit itself (chevron x grows).
      },
    );

    testWidgets(
      'mixed paths reach every document: qsort via mit/cprog/seminar, knn via mit/ml/lecture',
      (tester) async {
        // Tall viewport: the fully expanded lattice exceeds the default
        // 600px test surface and rows would scroll under the finder taps.
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

        // qsort is the only doc contained under study/mit/cprog → that
        // subtree collapses at cprog: the row lists qsort's remaining tag
        // (seminar) and expanding shows the doc link directly.
        await _tapNode(tester, ['study']);
        await _tapNode(tester, ['study', 'study/mit']);
        await _tapNode(tester, ['study', 'study/mit', 'study/mit/cprog']);
        expect(
          find.descendant(
            of: find.byKey(
              ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog'])),
            ),
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
        // No child directory rows inside the collapsed cprog subtree.
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

        // knn symmetric: collapses at ml with 'lecture' as remaining tag.
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

    testWidgets(
      'collapse study after expanding study/mit does not crash and preserves expanded state',
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

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
          findsOneWidget,
        );

        await tester.tap(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit', 'study/mit/ml']))),
          findsOneWidget,
        );

        // Collapse study — no exception; children disappear.
        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
          findsNothing,
        );

        // Re-expand study — mit is still expanded.
        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();
        expect(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit', 'study/mit/ml']))),
          findsOneWidget,
        );
      },
    );

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

        // study/mit row shows its per-component colorful path.
        expect(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
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
}
