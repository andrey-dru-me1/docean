import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/ui/widgets.dart'
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

    testWidgets(
      'renders the shared opaque tag-color pill on any theme',
      (tester) async {
        // The pill draws the grid-tile overlay style everywhere: an opaque
        // fill of the tag's own color with an opaque tag-colored ring and a
        // white shadowed label — the same in light and dark themes.
        for (final wrap in [_wrap, _wrapDark]) {
          await tester.pumpWidget(wrap(const TagChip(label: 'finance')));

          final color = tagColorFor('finance');
          final pill = _pillDecoration(tester);
          expect(pill.borderRadius, BorderRadius.circular(999));
          // Fully opaque: the resting pill is the tag's exact color and the
          // ring is an opaque lightened shade — no translucency anywhere.
          expect(pill.color, color);
          expect(
            (pill.border! as Border).top.color,
            Color.lerp(color, Colors.white, 0.12)!,
          );

          final chip = tester.widget<TagChip>(find.byType(TagChip));
          expect(chip.selected, isFalse);

          // White shadowed label for readability over the opaque fill.
          final text = tester.widget<Text>(find.text('finance'));
          expect(text.style?.color, Colors.white);
          expect(text.style?.shadows, isNotNull);
        }
      },
    );

    testWidgets('selected filter chips lighten toward white', (tester) async {
      await tester.pumpWidget(
        _wrap(const TagChip(label: 'finance', selected: true)),
      );

      final color = tagColorFor('finance');
      final pill = _pillDecoration(tester);
      // Selection lightens the background and ring toward white (both fully
      // opaque — never translucent).
      expect(pill.color, Color.lerp(color, Colors.white, 0.38)!);
      expect(pill.color!.a, 1.0);
      expect(
        (pill.border! as Border).top.color,
        Color.lerp(color, Colors.white, 0.42)!,
      );
    });

    testWidgets(
      'interactive pill lightens on mouse hover and shows a click cursor',
      (tester) async {
        var taps = 0;
        tester.view.physicalSize = const Size(400, 200);
        tester.view.devicePixelRatio = 1.0;
        addTearDown(tester.view.reset);

        await tester.pumpWidget(
          _wrap(
            TagChip(label: 'finance', onPressed: () => taps++),
          ),
        );

        final color = tagColorFor('finance');
        expect(_pillDecoration(tester).color, color);

        // Hover with a mouse pointer: the pill lightens but stays opaque.
        final chip = find.byType(TagChip);
        final mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: tester.getCenter(chip));
        await tester.pumpAndSettle();

        final hovered = _pillDecoration(tester);
        expect(hovered.color, Color.lerp(color, Colors.white, 0.22)!);
        expect(hovered.color!.a, 1.0);

        // The pill is tappable.
        await tester.tap(chip, warnIfMissed: false);
        expect(taps, 1);

        // Moving away restores the resting color.
        await mouse.moveTo(const Offset(-50, -50));
        await tester.pumpAndSettle();
        expect(_pillDecoration(tester).color, color);
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
            child: TagDeleteIcon(color: Colors.teal, onDeleted: () => taps++),
          ),
        ),
      );

      // On a mouse device the × starts hidden (opacity 0).
      final iconFinder = find.byIcon(Icons.clear);
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0);

      // Hover over the icon with a mouse; after the fade the × is visible and
      // rendered as a light-gray circle.
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: tester.getCenter(iconFinder));
      await tester.pumpAndSettle();
      final opacityAfter = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacityAfter.opacity, 1);

      // The × lives inside a light-gray circular disc.
      final circleContainer = find.ancestor(
        of: iconFinder,
        matching: find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).shape == BoxShape.circle,
        ),
      );
      expect(circleContainer, findsOneWidget);
      final circle = tester.widget<Container>(circleContainer);
      final decoration = circle.decoration! as BoxDecoration;
      expect(decoration.color, const Color(0xFFE0E0E0));

      // Tapping the visible × fires the delete callback.
      await tester.tap(iconFinder, warnIfMissed: false);
      expect(taps, 1);
    });
  });
}
