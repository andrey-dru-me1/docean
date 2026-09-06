import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart' show FakeDocumentService;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docer/src/ui/widgets.dart' show TagChip;

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
      // study/knn has 2 contained docs (knn, qsort).
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

      // Initially children are hidden.
      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsNothing);
      expect(find.byKey(const ValueKey('tag-node-study/lecture')), findsNothing);
      expect(find.byKey(const ValueKey('tag-node-study/seminar')), findsNothing);

      // Expand study.
      await tester.tap(find.byKey(const ValueKey('tag-node-study')));
      await tester.pumpAndSettle();

      // Children rendered in order: mit (dirtag), lecture (leaf), seminar (leaf).
      final mit = tester.getTopLeft(find.byKey(const ValueKey('tag-node-study/mit')));
      final lecture = tester.getTopLeft(find.byKey(const ValueKey('tag-node-study/lecture')));
      final seminar = tester.getTopLeft(find.byKey(const ValueKey('tag-node-study/seminar')));
      expect(mit.dy, lessThan(lecture.dy));
      expect(lecture.dy, lessThan(seminar.dy));
    });

    testWidgets(
      'expand study/mit shows cprog then ml, sub-tag row shows rotated parent and chip ml',
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
        await tester.tap(find.byKey(const ValueKey('tag-node-study/mit')));
        await tester.pumpAndSettle();

        // cprog and ml rows present and in alphabetical order.
        final cprog = tester.getTopLeft(find.byKey(const ValueKey('tag-node-study/mit/cprog')));
        final ml = tester.getTopLeft(find.byKey(const ValueKey('tag-node-study/mit/ml')));
        expect(cprog.dy, lessThan(ml.dy));

        // Rotated parent label 'mit' is present in the ml row.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-node-study/mit/ml')),
            matching: find.byType(RotatedBox),
          ),
          findsOneWidget,
        );
        // Chip label shows 'ml'.
        expect(
          find.descendant(
            of: find.byKey(const ValueKey('tag-node-study/mit/ml')),
            matching: find.text('ml'),
          ),
          findsOneWidget,
        );
        // find.text('study') multiple instances ok (top-level chip + rotated label).
        expect(find.text('study'), findsWidgets);
      },
    );

    testWidgets(
      'sub-tag chip for study/mit/ml has same color as study chip (top-level color)',
      (tester) async {
        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: _treeService(),
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();
        await _toggleToTags(tester);

        // Expand to reveal the ml node.
        await tester.tap(find.byKey(const ValueKey('tag-node-study')));
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const ValueKey('tag-node-study/mit')));
        await tester.pumpAndSettle();

        Color pillColor(Key nodeKey) {
          final pill = tester.widget<AnimatedContainer>(
            find.descendant(
              of: find.byKey(nodeKey),
              matching: find.byType(AnimatedContainer),
            ),
          );
          return (pill.decoration! as BoxDecoration).color!;
        }

        expect(
          pillColor(const ValueKey('tag-node-study/mit/ml')),
          pillColor(const ValueKey('tag-node-study')),
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

      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();

      // All nodes expanded, including deep ml and cprog.
      expect(find.byKey(const ValueKey('tag-node-study')), findsWidgets);
      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/mit/ml')), findsOneWidget);
      expect(find.byKey(const ValueKey('tag-node-study/mit/cprog')), findsOneWidget);

      // Collapse all.
      await tester.tap(find.byKey(const ValueKey('tag-tree-toggle-all')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('tag-node-study/mit')), findsNothing);
    });
  });

  // ---------------------------------------------------------------
  // Hierarchy-aware filter (startsWith rule)
  // ---------------------------------------------------------------
  group('hierarchy-aware filter', () {
    testWidgets(
      'selecting a tag filter selects its whole subtree via startsWith',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc('ml', 'ML only', tags: const ['study/mit/ml']),
            _doc('course', 'Course plan', tags: const ['study']),
            _doc('other', 'Groceries', tags: const ['personal']),
          ],
          tags: const ['study', 'study/mit/ml', 'personal'],
        );

        await tester.pumpWidget(
          _wrap(DocumentsScreen(
            documentService: service,
            onOpenDocument: (_) {},
          )),
        );
        await tester.pumpAndSettle();

        // All three visible before filtering.
        expect(find.text('ML only'), findsOneWidget);
        expect(find.text('Course plan'), findsOneWidget);
        expect(find.text('Groceries'), findsOneWidget);

        // Select the 'study' filter — matches exact + subtree.
        await tester.tap(find.byKey(const ValueKey('filter-study')));
        await tester.pumpAndSettle();

        // Both study-prefixed docs visible (ML only stays via startsWith).
        expect(find.text('ML only'), findsOneWidget);
        expect(find.text('Course plan'), findsOneWidget);
        // Doc without study prefix hidden.
        expect(find.text('Groceries'), findsNothing);
      },
    );
  });

  // ---------------------------------------------------------------
  // Empty state
  // ---------------------------------------------------------------
  group('TagHierarchyView empty state', () {
    testWidgets('shows "No tags yet" when all documents have only property tags',
        (tester) async {
      await tester.pumpWidget(
        _wrap(DocumentsScreen(
          documentService: FakeDocumentService(
            documents: [
              _doc('p1', 'Prop doc', tags: const ['student:Alice', 'scope:diploma']),
              _doc('p2', 'No tags'),
            ],
          ),
          onOpenDocument: (_) {},
        )),
      );
      await tester.pumpAndSettle();
      await _toggleToTags(tester);

      expect(find.text('No tags yet'), findsOneWidget);
    });
  });

  // ---------------------------------------------------------------
  // TagChip.onEdit rendering
  // ---------------------------------------------------------------
  group('TagChip.onEdit', () {
    testWidgets('renders edit affordance on the left and fires callback',
        (tester) async {
      var edited = false;
      await tester.pumpWidget(
        _wrap(TagChip(
          label: 'finance',
          onEdit: () => edited = true,
        )),
      );

      // Edit icon present in the tree (may be invisible until hover/touch).
      expect(find.byIcon(Icons.edit), findsOneWidget);

      // The GestureDetector is always hit-testable (behavior: opaque), so
      // tapping the edit key fires the callback even without hover.
      await tester.tap(find.byKey(const ValueKey('edit-finance')));
      await tester.pumpAndSettle();
      expect(edited, isTrue);
    });
  });
}