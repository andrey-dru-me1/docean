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
FakeDocumentService _treeService() => FakeDocumentService(
      documents: [
        _doc('knn', 'KNN notes', tags: const ['study/lecture', 'study/mit/ml']),
        _doc('qsort', 'Qsort impl', tags: const ['study/seminar', 'study/mit/cprog']),
        _doc('notes', 'Ideas', tags: const ['idea']),
        _doc('memo', 'TODOs', tags: const ['todo']),
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

      expect(find.byKey(const ValueKey('tag-node-study')), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(const ValueKey('tag-count-study')),
          matching: find.text('2'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('expand study shows children in order mit, lecture, seminar',
        (tester) async {
      await tester.pumpWidget(
        _wrap(DocumentsScreen(
          documentService: _treeService(),
          onOpenDocument: (_) {},
        )),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      expect(find.byKey(const ValueKey('tag-section-study/mit')), findsNothing);
      expect(find.byKey(const ValueKey('tag-section-study/lecture')), findsNothing);
      expect(find.byKey(const ValueKey('tag-section-study/seminar')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('tag-node-study')));
      await tester.pumpAndSettle();

      // Non-expanded subtags render as labeled section rows (owner study).
      final mit = tester.getTopLeft(find.byKey(const ValueKey('tag-section-study/mit')));
      final lecture = tester.getTopLeft(find.byKey(const ValueKey('tag-section-study/lecture')));
      final seminar = tester.getTopLeft(find.byKey(const ValueKey('tag-section-study/seminar')));
      expect(mit.dy, lessThan(lecture.dy));
      expect(lecture.dy, lessThan(seminar.dy));
    });

    testWidgets(
      'expand study/mit shows cprog then ml, '
      'sub-tag row renders colorful Text.rich and a rotated parent pill',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tag-section-study/mit')));
        await tester.pumpAndSettle();

        final cprog = tester.getTopLeft(find.byKey(const ValueKey('tag-section-study/mit/cprog')));
        final ml = tester.getTopLeft(find.byKey(const ValueKey('tag-section-study/mit/ml')));
        expect(cprog.dy, lessThan(ml.dy));

        // ml row: has a RotatedBox (the rotated parent pill) — exactly one.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit/ml')),
            matching: find.byType(RotatedBox),
          ),
          findsOneWidget,
        );

        // ml row: has the parent pill with key tag-parent-pill-study/mit.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit/ml')),
            matching: find.byKey(const ValueKey('tag-parent-pill-study/mit')),
          ),
          findsOneWidget,
        );

        // ml row: has colorful text containing 'study / mit / ml'.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit/ml')),
            matching: find.textContaining('study / mit / ml'),
          ),
          findsOneWidget,
        );

        // cprog row: colorful text containing 'study / mit / cprog'.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit/cprog')),
            matching: find.textContaining('study / mit / cprog'),
          ),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'unwound subtag sections: owner-labelled rows at the deepest level',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tag-section-study/mit')));
        await tester.pumpAndSettle();

        // Owner-mit section rows: study/mit's subtags at depth 2, labeled
        // '(mit) > mit / <sub>'.
        final cprog = tester.getTopLeft(
          find.byKey(const ValueKey('tag-section-study/mit/cprog')),
        );
        final ml = tester.getTopLeft(
          find.byKey(const ValueKey('tag-section-study/mit/ml')),
        );
        expect(cprog.dy, lessThan(ml.dy));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit/ml')),
            matching: find.textContaining('study / mit / ml'),
          ),
          findsOneWidget,
        );

        // Owner-study section: study's REMAINING subtags (lecture, seminar)
        // follow at the SAME deepest level, labeled '(study) > ...'.
        final lecture = tester.getTopLeft(
          find.byKey(const ValueKey('tag-section-study/lecture')),
        );
        final seminar = tester.getTopLeft(
          find.byKey(const ValueKey('tag-section-study/seminar')),
        );
        expect(ml.dy, lessThan(lecture.dy));
        expect(lecture.dy, lessThan(seminar.dy));
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/lecture')),
            matching: find.textContaining('study / lecture'),
          ),
          findsOneWidget,
        );

        // The expanded subtag itself (mit) keeps its navigational row style.
        expect(
          find.byKey(const ValueKey('tag-node-study/mit')),
          findsOneWidget,
        );
        // Section rows are NOT navigational rows (no duplicate rendering).
        expect(
          find.byKey(const ValueKey('tag-node-study/lecture')),
          findsNothing,
        );
      },
    );

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

        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();

        // study/mit row has colorful text containing 'study / mit'.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit')),
            matching: find.textContaining('study / mit'),
          ),
          findsOneWidget,
        );

        // No TagChip anywhere inside the tree rows (pills are replaced by text);
        // the filter-bar chips up top are outside the tree view.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-hierarchy-view')),
            matching: find.byType(TagChip),
          ),
          findsNothing,
        );

        // study/mit row's direct parent is 'study': rotated pill key
        // tag-parent-pill-study.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit')),
            matching: find.byKey(const ValueKey('tag-parent-pill-study')),
          ),
          findsOneWidget,
        );

        // study/mit row has a guide-line column for 'study' (level 1).
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-section-study/mit')),
            matching: find.byKey(const ValueKey('tag-guide-1')),
          ),
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

      expect(find.byKey(const ValueKey('tag-section-study/mit')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('tag-node-study')), findsWidgets);
      // Everything is expanded: every subtag keeps its navigational row.
      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/mit/ml')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/mit/cprog')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/lecture')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/seminar')), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsNothing);
    });

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

        // Expand study, then study/mit.
        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tag-section-study/mit')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('tag-section-study/mit')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tag-section-study/mit/ml')), findsOneWidget);

        // Collapse study — no exception; children disappear.
        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tag-node-study/mit')), findsNothing);
        expect(find.byKey(const ValueKey('tag-node-study/mit/ml')), findsNothing);

        // Re-expand study — study/mit is still expanded (previously-expanded state persists).
        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('tag-node-study/mit')), findsOneWidget);
        // mit is expanded but ml is not: ml stays a labeled section row.
        expect(find.byKey(const ValueKey('tag-section-study/mit/ml')), findsOneWidget);
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
