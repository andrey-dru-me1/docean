import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/features/tag_hierarchy.dart' show validateTagPath;
import 'package:docean/src/ui/tag_search_field.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

const _pool = [
  'study/mit/machine-learning',
  'study/mit/ml',
  'misc',
  'finance/q3',
];

void main() {
  group('TagSearchField', () {
    testWidgets('Enter selects the best match and the field clears', (
      tester,
    ) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _wrap(
          TagSearchField(
            keyPrefix: 'tsf',
            allTags: _pool,
            onSelected: picked.add,
          ),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pump();

      // Ranked completions: the exact-segment 'study/mit/ml' beats the
      // subsequence 'study/mit/machine-learning' (shorter first).
      expect(
        find.byKey(const ValueKey('tsf-suggestion-study/mit/ml')),
        findsOneWidget,
      );
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['study/mit/ml']);

      // Sequential: the field emptied but stays present (and focused).
      final TextField rendered = tester.widget(field);
      expect(rendered.controller!.text, isEmpty);
      expect(
        FocusManager.instance.primaryFocus?.hasFocus,
        isTrue,
        reason: 'keeps focus for the next tag',
      );
    });

    testWidgets('arrows move the highlight before Enter', (tester) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _wrap(
          TagSearchField(
            keyPrefix: 'tsf',
            allTags: _pool,
            onSelected: picked.add,
          ),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['study/mit/machine-learning']);
    });

    testWidgets('subsequence queries match the smart way', (tester) async {
      String? picked;
      await tester.pumpWidget(
        _wrap(
          TagSearchField(
            keyPrefix: 'tsf',
            allTags: _pool,
            onSelected: (t) => picked = t,
          ),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      // 'machine-le' → segment prefix.
      await tester.enterText(field, 'machine-le');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, 'study/mit/machine-learning');

      await tester.tap(field);
      await tester.pump();
      // 'smitml' → subsequence over the slashed-flat form.
      await tester.enterText(field, 'smitml');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, isNotNull);
    });

    testWidgets('free text submits only when allowed and valid', (
      tester,
    ) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _wrap(
          TagSearchField(
            keyPrefix: 'tsf',
            allTags: _pool,
            allowFreeText: true,
            submitValidator: validateTagPath,
            onSelected: picked.add,
          ),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();

      // A name matching nothing still submits (new tag).
      await tester.enterText(field, 'zzz-fresh');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['zzz-fresh']);

      // An invalid new name is rejected inline; nothing is submitted.
      await tester.enterText(field, '/oops');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(find.text('Tag must not start with a slash'), findsOneWidget);
      expect(picked, hasLength(1));
    });

    testWidgets('without free text, Enter on a no-match does nothing', (
      tester,
    ) async {
      final picked = <String>[];
      await tester.pumpWidget(
        _wrap(
          TagSearchField(
            keyPrefix: 'tsf',
            allTags: _pool,
            onSelected: picked.add,
          ),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'zzz');
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
    });

    testWidgets('Escape closes the panel and keeps the query', (tester) async {
      await tester.pumpWidget(
        _wrap(
          TagSearchField(keyPrefix: 'tsf', allTags: _pool, onSelected: (_) {}),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tsf-suggestion-study/mit/ml')),
        findsOneWidget,
      );
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('tsf-suggestion-study/mit/ml')),
        findsNothing,
      );
    });
  });
}
