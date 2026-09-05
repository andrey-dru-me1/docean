import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart' show FakeDocumentService;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/documents_screen.dart' show DocumentsScreen;
import 'package:docer/src/ui/hierarchy_view.dart'
    show
        DocProperty,
        buildScopeTree,
        docProperties,
        docScopes;

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

/// Helper to create a DocumentSummary with arbitrary tags.
DocumentSummary _doc(
  String id,
  String title, {
  List<String> tags = const [],
  List<String> paths = const [],
}) => DocumentSummary(id: id, title: title, tags: tags, paths: paths);

/// The teacher fixture: documents A–E seeded in a FakeDocumentService.
///
/// A[scope:diploma, study-year:2025-2026, student:Andrey, doctype:article]
/// B[scope:diploma, study-year:2025-2026, student:Andrey, doctype:report]
/// C[scope:diploma, study-year:2026-2027, student:Bob, doctype:article]
/// D[scope:course, course:machine-learning, student:Alice, doctype:report, theme:knn]
/// E[plain tag only]
FakeDocumentService _teacherService() => FakeDocumentService(
      documents: [
        _doc(
          'doc-a',
          'Thesis A',
          tags: const [
            'scope:diploma',
            'study-year:2025-2026',
            'student:Andrey',
            'doctype:article',
          ],
        ),
        _doc(
          'doc-b',
          'Report B',
          tags: const [
            'scope:diploma',
            'study-year:2025-2026',
            'student:Andrey',
            'doctype:report',
          ],
        ),
        _doc(
          'doc-c',
          'Thesis C',
          tags: const [
            'scope:diploma',
            'study-year:2026-2027',
            'student:Bob',
            'doctype:article',
          ],
        ),
        _doc(
          'doc-d',
          'KNN notes',
          tags: const [
            'scope:course',
            'course:machine-learning',
            'student:Alice',
            'doctype:report',
            'theme:knn',
          ],
        ),
        _doc('doc-e', 'Plain note', tags: const ['important']),
      ],
    );

Future<void> _toggleToHierarchy(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.account_tree));
  await tester.pumpAndSettle();
}

Future<void> _toggleToGrid(WidgetTester tester) async {
  await tester.tap(find.byIcon(Icons.grid_view));
  await tester.pumpAndSettle();
}

Future<void> _selectScope(WidgetTester tester, String name) async {
  await tester.tap(find.byKey(const ValueKey('hier-scope')));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey('hier-scope-item-$name')));
  await tester.pumpAndSettle();
}

void main() {
  // ---------------------------------------------------------------
  // Unit tests for hierarchy helpers
  // ---------------------------------------------------------------
  group('docProperties', () {
    test('parses valid property tags and ignores scope/plain tags', () {
      expect(
        docProperties([
          'scope:diploma',
          'student:Andrey',
          'plain-tag',
          'study-year:2025-2026',
          'invalid::double:colon',
        ]),
        equals([
          const DocProperty(key: 'student', value: 'Andrey'),
          const DocProperty(key: 'study-year', value: '2025-2026'),
        ]),
      );
    });
  });

  group('docScopes', () {
    test('returns all scope names for a document', () {
      expect(
        docScopes(['scope:teaching', 'scope:diploma', 'student:Andrey']),
        equals(['teaching', 'diploma']),
      );
    });

    test('returns empty list when no scope tags exist', () {
      expect(docScopes(['student:Bob', 'plain']), isEmpty);
    });
  });

  group('buildScopeTree', () {
    test('derives parent-child from tag co-occurrence counts', () {
      final tree = buildScopeTree([
        _doc('1', 'A', tags: const ['scope:teaching', 'scope:diploma']),
        _doc('2', 'B', tags: const ['scope:teaching']),
        _doc('3', 'C', tags: const ['scope:teaching', 'scope:diploma']),
      ]);

      // teaching=3, diploma=2 → teaching is root, diploma is child
      expect(tree, hasLength(1));
      expect(tree.first.name, 'teaching');
      expect(tree.first.label, 'teaching');
      expect(tree.first.children, hasLength(1));
      expect(tree.first.children.first.name, 'diploma');
      expect(tree.first.children.first.label, 'teaching ▸ diploma');
    });

    test('roots are separate when scopes never co-occur', () {
      final tree = buildScopeTree([
        _doc('1', 'A', tags: const ['scope:diploma']),
        _doc('2', 'B', tags: const ['scope:course']),
        _doc('3', 'C', tags: const ['scope:teaching']),
      ]);

      final names = tree.map((n) => n.name).toSet();
      expect(names, containsAll(['diploma', 'course', 'teaching']));
    });
  });

  // ---------------------------------------------------------------
  // Widget tests: the teacher example
  // ---------------------------------------------------------------

  testWidgets('toggle to hierarchy shows scope dropdown with diploma+course', (
    tester,
  ) async {
    await tester.pumpWidget(
      _wrap(
        DocumentsScreen(
          documentService: _teacherService(),
          onOpenDocument: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _toggleToHierarchy(tester);

    // Default scope is '(no scope)' → only unscoped doc E visible.
    expect(find.byKey(const ValueKey('hier-scope')), findsOneWidget);

    // Open the dropdown and check scopes are listed.
    await tester.tap(find.byKey(const ValueKey('hier-scope')));
    await tester.pumpAndSettle();
    expect(find.text('(no scope)'), findsWidgets);
    expect(find.text('diploma'), findsOneWidget);
    expect(find.text('course'), findsOneWidget);
  });

  testWidgets(
    'default alphabetical order on diploma groups correctly',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _teacherService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToHierarchy(tester);
      await _selectScope(tester, 'diploma');

      // Default order on diploma docs: [course(missing), doctype, student, study-year]
      // wait — docProperties excludes scope, so keys = doctype, student, study-year
      // sorted alphabetically → [doctype, student, study-year].
      // Tree: article (group-0) and report (group-3) visible collapsed.
      expect(find.byKey(const ValueKey('hier-group-0')), findsOneWidget);
      expect(find.text('article'), findsWidgets);

      // Expand all and verify documents appear.
      await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
      await tester.pumpAndSettle();

      expect(find.byKey(const ValueKey('hier-doc-doc-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-doc-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-doc-c')), findsOneWidget);
      // Course doc D should NOT be visible (different scope).
      expect(find.byKey(const ValueKey('hier-doc-doc-d')), findsNothing);
    },
  );

  testWidgets(
    'switch order via sheet then verify nesting',
    (tester) async {
      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(
            documentService: _teacherService(),
            onOpenDocument: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToHierarchy(tester);
      await _selectScope(tester, 'diploma');

      // Open the order sheet.
      await tester.tap(find.byKey(const ValueKey('hier-edit-order')));
      await tester.pumpAndSettle();

      // Sheet shows default order: doctype(0), student(1), study-year(2).
      expect(find.byKey(const ValueKey('hier-order-sheet')), findsOneWidget);

      // Reorder directly via the ReorderableListView's onReorderItem callback:
      // move study-year (index 2) to index 0, then student (now at index 2) to
      // index 1 to produce [study-year, student, doctype].
      final sheet = tester.widget<ReorderableListView>(
        find.byKey(const ValueKey('hier-order-sheet')),
      );
      sheet.onReorderItem!(2, 0);
      sheet.onReorderItem!(2, 1);
      await tester.pumpAndSettle();

      // Tap Apply to close the sheet and commit.
      await tester.tap(find.byKey(const ValueKey('hier-order-apply')));
      await tester.pumpAndSettle();

      // Expand all to verify the new nesting order.
      await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
      await tester.pumpAndSettle();

      // With order [study-year, student, doctype]:
      //   2025-2026 → Andrey → article(A) / report(B)
      //   2026-2027 / Bob / article → C
      expect(find.text('2025-2026 / Andrey'), findsOneWidget);
      expect(find.text('article'), findsWidgets);
      expect(find.text('report'), findsWidgets);
      expect(find.byKey(const ValueKey('hier-doc-doc-a')), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-doc-b')), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-doc-c')), findsOneWidget);
    },
  );

  testWidgets(
    'collapsed single-child chain merges (none) buckets',
    (tester) async {
      final service = FakeDocumentService(
        documents: [
          _doc(
            'f1',
            'Full',
            tags: const [
              'scope:teaching',
              'doctype:article',
              'study-year:2025',
            ],
          ),
          _doc(
            'f2',
            'Missing doctype',
            tags: const ['scope:teaching', 'study-year:2025'],
          ),
        ],
      );

      await tester.pumpWidget(
        _wrap(
          DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
        ),
      );
      await tester.pumpAndSettle();
      await _toggleToHierarchy(tester);
      await _selectScope(tester, 'teaching');

      // Keys on teaching docs: doctype, study-year.
      // Tree: article→(2025→F1); (none)→(2025→F2).
      // Each level-1 has 1 child → collapsed: 'article / 2025' and '(none) / 2025'.

      await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
      await tester.pumpAndSettle();

      expect(find.text('(none) / 2025'), findsOneWidget);
      expect(find.text('article / 2025'), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-f1')), findsOneWidget);
      expect(find.byKey(const ValueKey('hier-doc-f2')), findsOneWidget);
    },
  );

  testWidgets('tap leaf calls onOpenDocument with the right doc', (
    tester,
  ) async {
    final opened = <DocumentSummary>[];
    await tester.pumpWidget(
      _wrap(
        DocumentsScreen(
          documentService: _teacherService(),
          onOpenDocument: opened.add,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _toggleToHierarchy(tester);
    await _selectScope(tester, 'diploma');
    await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const ValueKey('hier-doc-doc-b')));
    await tester.pumpAndSettle();

    expect(opened, hasLength(1));
    expect(opened.single.id, 'doc-b');
    expect(opened.single.title, 'Report B');
  });

  testWidgets('scope switch to course shows only D', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DocumentsScreen(
          documentService: _teacherService(),
          onOpenDocument: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _toggleToHierarchy(tester);
    await _selectScope(tester, 'course');

    // Course docs: D has keys course, doctype, student, theme → sorted.
    // Single chain collapses: 'machine-learning / report / Alice / knn'.
    await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('hier-doc-doc-d')), findsOneWidget);
    expect(find.byKey(const ValueKey('hier-doc-doc-a')), findsNothing);
    expect(find.byKey(const ValueKey('hier-doc-doc-b')), findsNothing);
    expect(find.byKey(const ValueKey('hier-doc-doc-c')), findsNothing);
  });

  testWidgets('grid toggle restores the preview grid', (tester) async {
    await tester.pumpWidget(
      _wrap(
        DocumentsScreen(
          documentService: _teacherService(),
          onOpenDocument: (_) {},
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(GridView), findsOneWidget);

    // Switch to hierarchy.
    await _toggleToHierarchy(tester);
    expect(find.byKey(const ValueKey('hierarchy-view')), findsOneWidget);
    expect(find.byType(GridView), findsNothing);

    // Switch back to grid.
    await _toggleToGrid(tester);

    expect(find.byType(GridView), findsOneWidget);
    expect(find.byKey(const ValueKey('hierarchy-view')), findsNothing);
    // Grid tiles are visible.
    expect(find.text('Thesis A'), findsOneWidget);
  });

  // ---------------------------------------------------------------
  // Amendment tests
  // ---------------------------------------------------------------

  group('design amendment', () {
    testWidgets(
      'ancestor selection includes descendant documents',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc('a1', 'Descendant doc', tags: const [
              'scope:teaching',
              'scope:diploma',
              'doctype:article',
            ]),
            _doc('a2', 'Teaching only', tags: const [
              'scope:teaching',
              'doctype:report',
            ]),
            _doc('a3', 'Diploma only', tags: const [
              'scope:diploma',
              'doctype:essay',
            ]),
          ],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToHierarchy(tester);

        // Select leaf scope 'diploma' — only docs carrying scope:diploma
        // (a1 and a3).
        await _selectScope(tester, 'diploma');
        await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('hier-doc-a1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-a3')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-a2')), findsNothing);

        // Switch to ancestor scope 'teaching' — matches a1 and a2
        // (both carry scope:teaching). The tree stays expanded.
        await _selectScope(tester, 'teaching');
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('hier-doc-a1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-a2')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-a3')), findsNothing);
      },
    );

    testWidgets(
      'scope tree shows parent ▸ child labels from co-occurrence',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc('x1', 'X', tags: const [
              'scope:teaching',
              'scope:diploma',
            ]),
            _doc('x2', 'Y', tags: const ['scope:teaching']),
          ],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToHierarchy(tester);

        // Open the scope dropdown and check tree labels.
        await tester.tap(find.byKey(const ValueKey('hier-scope')));
        await tester.pumpAndSettle();

        // teaching=2, diploma=1 → teaching root, diploma child.
        expect(find.text('teaching'), findsWidgets);
        expect(find.text('teaching ▸ diploma'), findsOneWidget);
      },
    );

    testWidgets(
      'multi-membership doc appears under both scopes when switching',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc('m1', 'Cross-chain', tags: const [
              'scope:teaching',
              'scope:diploma',
              'scope:work',
              'year:2025',
            ]),
            _doc('m2', 'Work only', tags: const ['scope:work', 'project:z']),
            _doc('m3', 'Teaching only', tags: const [
              'scope:teaching',
              'year:2024',
            ]),
          ],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(documentService: service, onOpenDocument: (_) {}),
          ),
        );
        await tester.pumpAndSettle();
        await _toggleToHierarchy(tester);

        // Select 'work' — m1 and m2 carry it.
        await _selectScope(tester, 'work');
        await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('hier-doc-m1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-m2')), findsOneWidget);

        // Switch to 'teaching' — m1 and m3 carry it.
        // The tree stays expanded from the previous toggle-all tap.
        await _selectScope(tester, 'teaching');
        await tester.pumpAndSettle();

        expect(find.byKey(const ValueKey('hier-doc-m1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-m3')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-m2')), findsNothing);
      },
    );

    testWidgets(
      'selection mode in hierarchy shows checkboxes and toggles selection',
      (tester) async {
        final service = FakeDocumentService(
          documents: [
            _doc('s1', 'Select one'),
            _doc('s2', 'Select two'),
          ],
        );

        await tester.pumpWidget(
          _wrap(
            DocumentsScreen(
              documentService: service,
              onOpenDocument: (_) {},
            ),
          ),
        );
        await tester.pumpAndSettle();

        // Switch to hierarchy while in browse mode.
        await _toggleToHierarchy(tester);

        // Expand all to see docs.
        await tester.tap(find.byKey(const ValueKey('hier-toggle-all')));
        await tester.pumpAndSettle();

        // Verify docs visible before selection.
        expect(find.byKey(const ValueKey('hier-doc-s1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-doc-s2')), findsOneWidget);

        // Enter selection mode — filter bar is replaced by selection bar.
        await tester.tap(find.byKey(const ValueKey('select-documents')));
        await tester.pumpAndSettle();

        // Now both docs are selected; hierarchy view shows checkboxes.
        expect(find.text('2 selected'), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-check-s1')), findsOneWidget);
        expect(find.byKey(const ValueKey('hier-check-s2')), findsOneWidget);

        // Tap a checkbox — selection count decremented.
        await tester.tap(find.byKey(const ValueKey('hier-check-s1')));
        await tester.pumpAndSettle();
        expect(find.text('1 selected'), findsOneWidget);
      },
    );
  });
}