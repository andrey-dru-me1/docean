import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart' show FakeDocumentService;
import 'package:docer/src/ui/document_view.dart' show DocumentDetailView, DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docer/src/ui/widgets.dart' show TagChip, tagColorFor;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

DocumentSummary _doc(
  String id,
  String title, {
  List<String> tags = const [],
  List<String> paths = const [],
}) => DocumentSummary(id: id, title: title, tags: tags, paths: paths);

/// The standard fixture used across tree-structure tests.
///
/// knn[study/lecture, study/mit/ml]
/// qsort[study/seminar, study/mit/cprog]
/// notes[idea]   (plain top-level leaf)
/// memo[todo]    (plain top-level leaf)
FakeDocumentService _treeService({bool withNestedFiles = false, bool withRootFile = false}) =>
    FakeDocumentService(
      documents: [
        _doc('knn', 'KNN notes', tags: const ['study/lecture', 'study/mit/ml']),
        _doc('qsort', 'Qsort impl', tags: const ['study/seminar', 'study/mit/cprog']),
        _doc('notes', 'Ideas', tags: const ['idea']),
        _doc('memo', 'TODOs', tags: const ['todo']),
        if (withNestedFiles)
          _doc('mit-notes', 'MIT notes', tags: const ['study/mit']),
        if (withRootFile)
          _doc('study-doc', 'Study doc', tags: const ['study']),
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
  await tester.tap(find.byIcon(Icons.sell));
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------
  // Own colors: tagColorFor hashes the full path, not just top-level
  // ---------------------------------------------------------------
  group('own colors', () {
    test('tagColorFor produces distinct colors for each hierarchical level', () {
      expect(tagColorFor('study'), isNot(equals(tagColorFor('study/mit'))));
      expect(
        tagColorFor('study/mit'),
        isNot(equals(tagColorFor('study/mit/ml'))),
      );
      expect(
        tagColorFor('study'),
        isNot(equals(tagColorFor('study/mit/ml'))),
      );
    });
  });

  // ---------------------------------------------------------------
  // Split pill (TagChip)
  // ---------------------------------------------------------------
  group('split pill', () {
    testWidgets(
      'pumping TagChip(label: study/mit/ml) renders 3 colored segments '
      'and 2 dividers',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const TagChip(label: 'study/mit/ml')),
        );

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
              (w) =>
                  w is ColoredBox && w.color == Colors.white24,
            ),
          ),
          findsNWidgets(2),
        );
      },
    );

    testWidgets(
      'split pill selected state lightens every segment color',
      (tester) async {
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

        expect(blockColor('study'), Color.lerp(tagColorFor('study'), Colors.white, 0.38)!);
        expect(blockColor('mit'), Color.lerp(tagColorFor('study/mit'), Colors.white, 0.38)!);
        expect(blockColor('ml'), Color.lerp(tagColorFor('study/mit/ml'), Colors.white, 0.38)!);
      },
    );
  });

  // ---------------------------------------------------------------
  // Tag hierarchy tree view
  // ---------------------------------------------------------------
  // Expansion/row keys in the component-lattice model.
  const pathSep = '\u0000';
  String nodeKey(List<String> comps) => 'tag-node-${comps.join(pathSep)}';
  String docRowKey(String id, List<String> comps) =>
      'tag-doc-$id@${comps.join(pathSep)}';

  group('TagHierarchyView tree', () {
    testWidgets('shows top-level study with count badge 2', (tester) async {
      await tester.pumpWidget(
        _wrap(DocumentsScreen(
          documentService: _treeService(),
          onOpenDocument: (_) {},
        )),
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
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();

        final ys = [
          tester.getTopLeft(find.byKey(ValueKey(nodeKey(['study', 'study/mit'])))).dy,
          tester.getTopLeft(find.byKey(ValueKey(nodeKey(['study', 'study/lecture'])))).dy,
          tester.getTopLeft(find.byKey(ValueKey(nodeKey(['study', 'study/seminar'])))).dy,
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
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
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
        expect(
          tester.getTopLeft(cprog).dy, lessThan(tester.getTopLeft(ml).dy),
        );
        expect(
          tester.getTopLeft(ml).dy, lessThan(tester.getTopLeft(lecture).dy),
        );
        expect(
          tester.getTopLeft(lecture).dy, lessThan(tester.getTopLeft(seminar).dy),
        );
        // mit's children sit deeper than mit itself (chevron x grows).
        final mitChevron = tester.getTopLeft(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
            matching: find.byIcon(Icons.expand_more),
          ),
        ).dx;
        final cprogChevron = tester.getTopLeft(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog']))),
            matching: find.byIcon(Icons.expand_more),
          ),
        ).dx;
        expect(cprogChevron, greaterThan(mitChevron));
      },
    );

    testWidgets(
      'mixed paths reach every document: qsort via mit/cprog/seminar, knn via mit/ml/lecture',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        // qsort: study -> mit -> cprog -> seminar.
        for (final comps in [
          ['study'],
          ['study', 'study/mit'],
          ['study', 'study/mit', 'study/mit/cprog'],
          ['study', 'study/mit', 'study/mit/cprog', 'study/seminar'],
        ]) {
          await tester.tap(find.byKey(ValueKey(nodeKey(comps))));
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(ValueKey(docRowKey(
            'qsort',
            ['study', 'study/mit', 'study/mit/cprog', 'study/seminar'],
          ))),
          findsOneWidget,
        );

        // The seminar row's rotated pill names its REAL parent (study), not
        // the walk parent (study/mit/cprog).
        expect(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(
              ['study', 'study/mit', 'study/mit/cprog', 'study/seminar'],
            ))),
            matching: find.byKey(const ValueKey('tag-parent-pill-study')),
          ),
          findsOneWidget,
        );

        // knn: study -> mit -> ml -> lecture.
        for (final comps in [
          ['study', 'study/mit', 'study/mit/ml'],
          ['study', 'study/mit', 'study/mit/ml', 'study/lecture'],
        ]) {
          await tester.tap(find.byKey(ValueKey(nodeKey(comps))));
          await tester.pumpAndSettle();
        }
        expect(
          find.byKey(ValueKey(docRowKey(
            'knn',
            ['study', 'study/mit', 'study/mit/ml', 'study/lecture'],
          ))),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'files: root directory defers below sections, nested files stay in place',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(withNestedFiles: true, withRootFile: true),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(ValueKey(nodeKey(['study']))));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))));
        await tester.pumpAndSettle();

        // mit's own file: inline, right below mit's children (cprog, lecture,
        // ml, seminar) and ABOVE study's deferred file.
        final mitNotes = tester.getTopLeft(
          find.byKey(ValueKey(docRowKey(
            'mit-notes',
            ['study', 'study/mit'],
          ))),
        );
        final cprog = tester.getTopLeft(
          find.byKey(ValueKey(nodeKey(['study', 'study/mit', 'study/mit/cprog']))),
        );
        expect(cprog.dy, lessThan(mitNotes.dy));

        // Root directory file: below ALL subtag rows.
        final studyDoc = tester.getTopLeft(
          find.byKey(ValueKey(docRowKey('study-doc', ['study']))),
        );
        expect(mitNotes.dy, lessThan(studyDoc.dy));
        final seminar = tester.getTopLeft(
          find.byKey(ValueKey(nodeKey(['study', 'study/seminar']))),
        );
        expect(seminar.dy, lessThan(studyDoc.dy));
      },
    );

    testWidgets(
      'collapse study after expanding study/mit does not crash and preserves expanded state',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
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

    testWidgets('tag-tree-toggle-all expands and collapses all', (tester) async {
      await tester.pumpWidget(
        _wrap(DocumentsScreen(
          documentService: _treeService(),
          onOpenDocument: (_) {},
        )),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      expect(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();

      // Both documents reachable through their full walks.
      expect(
        find.byKey(ValueKey(docRowKey(
          'knn',
          ['study', 'study/mit', 'study/mit/ml', 'study/lecture'],
        ))),
        findsOneWidget,
      );
      expect(
        find.byKey(ValueKey(docRowKey(
          'qsort',
          ['study', 'study/mit', 'study/mit/cprog', 'study/seminar'],
        ))),
        findsOneWidget,
      );

      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(ValueKey(nodeKey(['study', 'study/mit']))), findsNothing);
    });

    testWidgets(
      'tree rows render colorful Text.rich path and contain no TagChip',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
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

        // study/mit row's gutter: rotated parent pill for 'study'.
        expect(
          find.descendant(
            of: find.byKey(ValueKey(nodeKey(['study', 'study/mit']))),
            matching: find.byKey(const ValueKey('tag-parent-pill-study')),
          ),
          findsOneWidget,
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
            _doc('d1', 'Deep doc', tags: [
              'study',
              'study/mit',
              'study/mit/ml',
              'student:Alice',
            ]),
          ],
          tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
        );

        final doc = _doc('d1', 'Deep doc', tags: [
          'study',
          'study/mit',
          'study/mit/ml',
          'student:Alice',
        ]);

        await tester.pumpWidget(
          _wrap(DocumentDetailView(
            document: doc,
            documentService: service,
          )),
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
            _doc('d1', 'Deep doc', tags: [
              'study',
              'study/mit',
              'study/mit/ml',
              'student:Alice',
            ]),
          ],
          tags: ['study', 'study/mit', 'study/mit/ml', 'student:Alice'],
        );

        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: service,
            onOpenDocument: (_) {},
          )),
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
