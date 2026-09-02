import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/ui/widgets.dart'
    show TagChip, TagDeleteIcon, tagColorFor, tagTintFor;

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

void main() {
  group('TagChip', () {
    testWidgets('renders without a reserved avatar slot in the chip', (
      tester,
    ) async {
      await tester.pumpWidget(_wrap(const TagChip(label: 'finance')));

      // The chip has no avatar (a zero-size avatar placeholder still reserves
      // the avatar slot and would push the label away from the left edge).
      final chipWidget = tester.widget<Chip>(find.byType(Chip));
      expect(chipWidget.avatar, isNull);

      // The label starts right after the chip's own horizontal padding (now 4),
      // i.e. at the chip's left edge — not after an avatar gap.
      final chip = find.byType(Chip);
      final label = find.text('finance');
      final chipLeft = tester.getTopLeft(chip).dx;
      final labelLeft = tester.getTopLeft(label).dx;
      expect(labelLeft - chipLeft, greaterThanOrEqualTo(0));
      expect(labelLeft - chipLeft, lessThan(12));
    });

    testWidgets('uses tighter compact padding', (tester) async {
      await tester.pumpWidget(_wrap(const TagChip(label: 'finance')));

      final chipWidget = tester.widget<Chip>(find.byType(Chip));
      // Reduced padding (horizontal 4) / labelPadding (horizontal 2) so chips
      // pack tighter in Wraps.
      expect(chipWidget.padding, const EdgeInsets.symmetric(horizontal: 4));
      expect(
        chipWidget.labelPadding,
        const EdgeInsets.symmetric(horizontal: 2),
      );
    });

    testWidgets(
      'dark theme tint is a light, surface-blended color — not a dark wash',
      (tester) async {
        await tester.pumpWidget(
          _wrapDark(const TagChip(label: 'finance')),
        );

        final context = tester.element(find.byType(TagChip));
        final chipWidget = tester.widget<Chip>(find.byType(Chip));
        final tint = tagTintFor(context, 'finance');

        // The chip actually uses that light tint in dark mode.
        final scheme = Theme.of(context).colorScheme;
        expect(scheme.brightness, Brightness.dark);
        final bg = chipWidget.backgroundColor!;

        // The dark tint must be opaque (surface-blended) and clearly LIGHTER
        // than the deterministic tag color (a dark material 900 shade) so the
        // chip reads as a visible colored pill rather than a near-black smudge
        // (the old 0.16 alpha wash over a dark surface landed around 0.02).
        expect(tint.computeLuminance(), greaterThan(0.15));
        // Brighter than the old 0.16-alpha wash over the same surface.
        final oldWashLuminance = Color.alphaBlend(
          tagColorFor('finance').withValues(alpha: 0.16),
          scheme.surface,
        ).computeLuminance();
        expect(tint.computeLuminance(), greaterThan(oldWashLuminance * 3));
        expect(bg, tint);
        expect(bg.a, greaterThan(0.55));
      },
    );

    testWidgets(
      'overlay variant keeps the tag color identity with a white label',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const TagChip(label: 'finance', overlay: true)),
        );

        final chipWidget = tester.widget<Chip>(find.byType(Chip));
        final color = tagColorFor('finance');
        // Translucent tint of the tag's own color (not a mono black scrim).
        expect(chipWidget.backgroundColor, isNotNull);
        expect(chipWidget.backgroundColor!.a, greaterThan(0.35));
        expect(chipWidget.backgroundColor!.a, lessThan(1.0));
        expect(chipWidget.backgroundColor, color.withValues(alpha: 0.55));
        // Tag-colored border, not a white ring.
        expect(chipWidget.side?.color, color.withValues(alpha: 0.85));
        expect(
          chipWidget.side?.color,
          isNot(const Color(0x47FFFFFF)), // old white ring
        );
        // White label for readability over arbitrary preview content.
        expect(chipWidget.labelStyle?.color, Colors.white);
      },
    );
  });

  group('TagDeleteIcon', () {
    testWidgets('delete X is hidden until the mouse hovers and then appears', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(400, 200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        _wrap(const TagDeleteIcon(color: Colors.teal)),
      );

      // On a mouse device the X starts hidden (opacity 0).
      final iconFinder = find.byIcon(Icons.clear);
      final opacity = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacity.opacity, 0);

      // Hover over the icon with a mouse; after the fade the X is visible.
      final mouse = await tester.createGesture(
        kind: PointerDeviceKind.mouse,
      );
      await mouse.addPointer(location: tester.getCenter(iconFinder));
      await tester.pumpAndSettle();
      final opacityAfter = tester.widget<AnimatedOpacity>(
        find.byType(AnimatedOpacity),
      );
      expect(opacityAfter.opacity, 1);
    });
  });
}
