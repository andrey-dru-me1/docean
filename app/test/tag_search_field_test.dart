import 'package:flutter/gestures.dart' show PointerDeviceKind;
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

    testWidgets('create row sits under exact matches, arrows reach it', (
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
      await tester.enterText(field, 'ml');
      await tester.pump();

      // Create offered (no exact 'ml' tag) above the fuzzy matches; the
      // DEFAULT highlight is still the best real match.
      expect(find.byKey(const ValueKey('tsf-create')), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['study/mit/ml'], reason: 'Enter picks the real match');

      // One ArrowUp wraps from the first tag onto the create row.
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['study/mit/ml', 'ml'], reason: 'create row via arrows');

      // An exact match hides the create row (it would be a no-op).
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'misc');
      await tester.pump();
      expect(find.byKey(const ValueKey('tsf-create')), findsNothing);
      expect(find.byKey(const ValueKey('tsf-suggestion-misc')), findsOneWidget);
    });

    testWidgets('zero matches still offer creation', (tester) async {
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
      await tester.enterText(field, 'zzz-new');
      await tester.pump();
      expect(find.byKey(const ValueKey('tsf-create')), findsOneWidget);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['zzz-new']);
    });

    testWidgets('the drawn highlight follows the arrows', (tester) async {
      // Regression: _moveActive updated the state (Enter picked the right
      // row) but the OverlayEntry subtree was never rebuilt, so the visible
      // highlight stayed on the first row.
      await tester.pumpWidget(
        _wrap(
          TagSearchField(keyPrefix: 'tsf', allTags: _pool, onSelected: (_) {}),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pumpAndSettle();

      final ml = find.byKey(const ValueKey('tsf-suggestion-study/mit/ml'));
      final machine = find.byKey(
        const ValueKey('tsf-suggestion-study/mit/machine-learning'),
      );
      // Default: best match highlighted, the other plain.
      expect(tester.widget<Container>(ml).color, isNotNull);
      expect(tester.widget<Container>(machine).color, isNull);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pumpAndSettle();
      expect(
        tester.widget<Container>(ml).color,
        isNull,
        reason: 'highlight must leave the first row',
      );
      expect(
        tester.widget<Container>(machine).color,
        isNotNull,
        reason: 'highlight must follow to the next row',
      );
    });

    testWidgets('hovering a row moves the highlight and tags never wrap', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          TagSearchField(keyPrefix: 'tsf', allTags: _pool, onSelected: (_) {}),
        ),
      );
      final field = find.byKey(const ValueKey('tsf-field'));
      await tester.tap(field);
      await tester.pump();
      await tester.enterText(field, 'ml');
      await tester.pumpAndSettle();

      final ml = find.byKey(const ValueKey('tsf-suggestion-study/mit/ml'));
      final machine = find.byKey(
        const ValueKey('tsf-suggestion-study/mit/machine-learning'),
      );
      expect(tester.widget<Container>(ml).color, isNotNull);
      expect(tester.widget<Container>(machine).color, isNull);

      // One row must stay one line — long paths ellipsize, never wrap/clip.
      final machineText = tester.widget<Text>(
        find.descendant(of: machine, matching: find.byType(Text)),
      );
      expect(machineText.maxLines, 1);
      expect(machineText.overflow, TextOverflow.ellipsis);

      // Mouse hover drives the same highlight as the arrows.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(4, 4));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(tester.getCenter(machine));
      await tester.pumpAndSettle();
      expect(
        tester.widget<Container>(ml).color,
        isNull,
        reason: 'hover must clear the old highlight',
      );
      expect(
        tester.widget<Container>(machine).color,
        isNotNull,
        reason: 'hovered row must become highlighted',
      );
    });

    testWidgets('after Escape, Enter submits the raw input, not a match', (
      tester,
    ) async {
      // Regression: matches existed for 'ml', but the user dismissed the
      // panel with Escape to create their own tag — Enter still picked the
      // highlighted completion.
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

      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, ['ml'], reason: 'raw input created after Escape');
    });

    testWidgets('after Escape, Enter stays inert without free text', (
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
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(picked, isEmpty);
    });
  });
}
