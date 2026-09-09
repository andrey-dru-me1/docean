import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/ui/widgets.dart'
    show TagChip, TagDeleteIcon, tagColorFor;

Widget _wrap(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

/// A minimal dark MaterialApp so [tagTintFor] resolves a dark [ColorScheme].
Widget _wrapDark(Widget child) => MaterialApp(
  theme: ThemeData(
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    ),
  ),
  home: Scaffold(body: Center(child: child)),
);

/// The tag pill's [BoxDecoration] (findable via the rendered [AnimatedContainer]).
BoxDecoration _pillDecoration(WidgetTester tester) {
  final container = tester.widget<AnimatedContainer>(
    find.descendant(
      of: find.byType(TagChip),
      matching: find.byType(AnimatedContainer),
    ),
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  group('TagChip', () {
    testWidgets(
      'hierarchical pills compress to letters with a fixed hover-invariant width',
      (tester) async {
        // The test binding reports TargetPlatform.android by default; hover
        // compression is a desktop feature.
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        await tester.pumpWidget(
          _wrap(const TagChip(label: 'study/mit/courses')),
        );
        await tester.pumpAndSettle();

        final pill = find.byKey(const ValueKey('tag-pill'));
        expect(pill, findsOneWidget);
        final restingWidth = tester.getSize(pill).width;
        // At rest the longest parent shows a prefix of its reserved slack,
        // the other collapses to one letter — never the full name.
        expect(find.text('study'), findsNothing);
        expect(find.text('mit'), findsNothing);
        expect(find.text('courses'), findsOneWidget);
        // Exact fits show no ellipsis: letters and the full leaf are not cuts.
        expect(find.textContaining('…'), findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(10, 10));
        addTearDown(mouse.removePointer);

        // Hovering a parent expands THAT segment to its full name while the
        // pill width stays pinned (no jumping layout). Hover is resolved
        // geometrically from the pill row, so aim at the first block.
        Future<void> hoverSegment(int index) async {
          await mouse.moveTo(
            tester.getCenter(find.byKey(ValueKey('seg-block-$index'))),
          );
          await tester.pump();
          await tester.pumpAndSettle();
        }

        await hoverSegment(0);
        await tester.pumpAndSettle();
        expect(find.text('study'), findsOneWidget);
        expect(tester.getSize(pill).width, restingWidth);

        await hoverSegment(1);
        // Hovering the middle: it reaches full width and the NEAREST
        // neighbour (left, ahead of the leaf in tie order) also shows its
        // full word; the leaf yields and cuts to one letter.
        expect(find.text('mit'), findsOneWidget);
        expect(find.text('study'), findsOneWidget);
        expect(find.text('courses'), findsNothing);
        expect(tester.getSize(pill).width, restingWidth);

        // Leaving collapses back to the resting layout.
        await mouse.moveTo(const Offset(10, 10));
        await tester.pumpAndSettle();
        expect(find.text('mit'), findsNothing);
        expect(tester.getSize(pill).width, restingWidth);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets(
      'hovering the left segment lets the middle neighbour reach full width',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
        // 'q / middle / looooooo' — the LEAF is the widest cell, so at rest
        // the middle neighbour is just the letter 'm'.
        await tester.pumpWidget(
          _wrap(const TagChip(label: 'q/middle/looooooo')),
        );
        await tester.pumpAndSettle();
        final pill = find.byKey(const ValueKey('tag-pill'));
        final width = tester.getSize(pill).width;
        expect(find.text('middle'), findsNothing);

        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: const Offset(5, 5));
        addTearDown(mouse.removePointer);
        // Hovering the left cell ('q' — already at cap) must give the FULL
        // width to its nearest neighbour ('middle'), leaving the leaf cut.
        await mouse.moveTo(
          tester.getCenter(find.byKey(const ValueKey('seg-block-0'))),
        );
        await tester.pump();
        await tester.pumpAndSettle();
        expect(find.text('middle'), findsOneWidget);
        // The leaf yielded room for the neighbour: its mid-word cut is
        // marked with an ellipsis.
        expect(find.text('lo…'), findsOneWidget);
        expect(tester.getSize(pill).width, width);
        debugDefaultTargetPlatformOverride = null;
      },
    );

    testWidgets('resting prefix extensions are marked with an ellipsis', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(_wrap(const TagChip(label: 'longword/x/yy')));
      await tester.pumpAndSettle();
      // The pill is pinned to its widest (hover) state, so at rest the
      // reserved spare extends 'longword' past its letter — but the word
      // cannot fit fully, and the cut is ellipsized. The leaf stays whole.
      expect(find.text('longword'), findsNothing);
      expect(find.text('yy'), findsOneWidget);
      expect(find.textContaining('…'), findsOneWidget);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('compressed pill clamps to a tight cell and ellipsizes', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 150,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TagChip(label: 'ngu/practice/review supervisor'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final pill = find.byKey(const ValueKey('tag-pill'));
      expect(tester.getSize(pill).width, lessThanOrEqualTo(150));
      // The leaf takes the first cut and says so with an ellipsis.
      expect(find.textContaining('…'), findsWidgets);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('hover expansion on a clamped pill still fits the cell', (
      tester,
    ) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      await tester.pumpWidget(
        _wrap(
          const SizedBox(
            width: 150,
            child: Align(
              alignment: Alignment.centerLeft,
              child: TagChip(label: 'ngu/practice/review supervisor'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: const Offset(5, 5));
      addTearDown(mouse.removePointer);
      await mouse.moveTo(
        tester.getCenter(find.byKey(const ValueKey('seg-block-1'))),
      );
      await tester.pump();
      await tester.pumpAndSettle();

      expect(tester.takeException(), isNull);
      final pill = find.byKey(const ValueKey('tag-pill'));
      expect(tester.getSize(pill).width, lessThanOrEqualTo(150));
      // Sum of blocks still equals the clamped width: segments co-cut.
      expect(find.textContaining('…'), findsWidgets);
      debugDefaultTargetPlatformOverride = null;
    });

    testWidgets('renders a compact pill with no reserved avatar slot', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const TagChip(label: 'finance')));

      // A custom pill, not a Material Chip: the pill's container has no avatar
      // concept, and the label sits right after the pill's own horizontal
      // padding (8), i.e. at the pill's left edge.
      final pill = find.byType(AnimatedContainer);
      final label = find.text('finance');
      final pillLeft = tester.getTopLeft(pill).dx;
      final labelLeft = tester.getTopLeft(label).dx;
      expect(labelLeft - pillLeft, greaterThanOrEqualTo(0));
      expect(labelLeft - pillLeft, lessThan(20));
    });

    testWidgets('uses compact pill padding', (tester) async {
      await tester.pumpWidget(_wrap(const TagChip(label: 'finance')));

      final container = tester.widget<AnimatedContainer>(
        find.byType(AnimatedContainer),
      );
      // Compact horizontal padding (8) so pills pack tighter in Wraps; the
      // vertical (5) keeps the pill short but gives the 11.5px label room.
      expect(
        container.padding,
        const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
      );
    });

    testWidgets('renders the shared opaque tag-color pill on any theme', (
      tester,
    ) async {
      // The pill draws the grid-tile overlay style everywhere: an opaque
      // fill of the tag's own color with an opaque tag-colored ring and a
      // white shadowed label — the same in light and dark themes.
      for (final wrap in [_wrap, _wrapDark]) {
        await tester.pumpWidget(wrap(const TagChip(label: 'finance')));

        final color = tagColorFor('finance');
        final pill = _pillDecoration(tester);
        expect(pill.borderRadius, BorderRadius.circular(999));
        // Fully opaque: the resting pill is the tag's exact color — and no
        // border (borders break the divided-pill look on hierarchical tags).
        expect(pill.color, color);
        expect(pill.border, isNull);

        final chip = tester.widget<TagChip>(find.byType(TagChip));
        expect(chip.selected, isFalse);

        // White shadowed label for readability over the opaque fill.
        final text = tester.widget<Text>(find.text('finance'));
        expect(text.style?.color, Colors.white);
        expect(text.style?.shadows, isNotNull);
      }
    });

    testWidgets('selected filter chips lighten toward white', (tester) async {
      await tester.pumpWidget(
        _wrap(const TagChip(label: 'finance', selected: true)),
      );

      final color = tagColorFor('finance');
      final pill = _pillDecoration(tester);
      // Selection lightens the background toward white (fully opaque — never
      // translucent); no border.
      expect(pill.color, Color.lerp(color, Colors.white, 0.38)!);
      expect(pill.color!.a, 1.0);
      expect(pill.border, isNull);
    });

    testWidgets(
      'interactive pill stays visually constant on mouse hover and has no click cursor',
      (tester) async {
        var taps = 0;
        tester.view.physicalSize = const Size(400, 200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrap(TagChip(label: 'finance', onPressed: () => taps++)),
        );

        final color = tagColorFor('finance');
        expect(_pillDecoration(tester).color, color);

        // Hover with a mouse pointer: the pill neither lightens nor swaps its
        // cursor — no hover feedback beyond the (absent here) delete ×.
        final chip = find.byType(TagChip);
        final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
        await mouse.addPointer(location: tester.getCenter(chip));
        await tester.pumpAndSettle();

        final hovered = _pillDecoration(tester);
        expect(hovered.color, color);
        expect(
          find.descendant(of: chip, matching: find.byType(MouseRegion)),
          findsNothing,
          reason: 'the TagChip must not wrap its pill in a MouseRegion',
        );

        // The pill is still tappable.
        await tester.tap(chip, warnIfMissed: false);
        expect(taps, 1);
      },
    );
  });

  group('TagDeleteIcon', () {
    testWidgets('delete × is hidden until the mouse hovers and then appears', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      var taps = 0;
      await tester.pumpWidget(
        _wrap(
          SizedBox(
            width: 100,
            height: 32,
            child: TagDeleteIcon(
              background: Colors.teal,
              onDeleted: () => taps++,
            ),
          ),
        ),
      );

      // On a mouse device the × starts hidden (opacity 0).
      final iconFinder = find.byIcon(Icons.clear);
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0);

      // Hover over the icon with a mouse; after the fade the × is visible.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(iconFinder));
      await tester.pumpAndSettle();
      final opacityAfter = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacityAfter.opacity, 1);

      // No circular disc: the cross is a bare white × (with a soft shadow) —
      // the only circle/decorated container is gone.
      expect(
        find.ancestor(
          of: iconFinder,
          matching: find.byWidgetPredicate(
            (w) =>
                w is Container &&
                w.decoration is BoxDecoration &&
                (w.decoration! as BoxDecoration).shape == BoxShape.circle,
          ),
        ),
        findsNothing,
      );
      final icon = tester.widget<Icon>(iconFinder);
      expect(icon.color, Colors.white);
      expect(icon.shadows, isNotNull);

      // The dimming scrim: a horizontal gradient that starts with the pill's
      // own fill (opaque) and fades to transparent rightward.
      final scrim = tester.widget<DecoratedBox>(
        find.descendant(
          of: find.byType(TagDeleteIcon),
          matching: find.byType(DecoratedBox),
        ),
      );
      final scrimDecoration = scrim.decoration as BoxDecoration;
      final gradient = scrimDecoration.gradient! as LinearGradient;
      expect(gradient.colors.first, Colors.teal);
      expect(gradient.colors.first.a, 1.0);
      expect(gradient.colors.last.a, 0.0);
      expect(gradient.begin, Alignment.centerLeft);
      expect(gradient.end, Alignment.centerRight);

      // Tapping the visible × fires the delete callback.
      await tester.tap(iconFinder, warnIfMissed: false);
      expect(taps, 1);
    });
  });
}
