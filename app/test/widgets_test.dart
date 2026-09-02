import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/ui/widgets.dart' show TagChip;

Widget _wrap(Widget child) => MaterialApp(
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

      // The label starts right after the chip's own horizontal padding (6),
      // i.e. at the chip's left edge — not after an avatar gap.
      final chip = find.byType(Chip);
      final label = find.text('finance');
      final chipLeft = tester.getTopLeft(chip).dx;
      final labelLeft = tester.getTopLeft(label).dx;
      expect(labelLeft - chipLeft, greaterThanOrEqualTo(0));
      expect(labelLeft - chipLeft, lessThan(12));
    });

    testWidgets(
      'overlay variant uses a dark translucent scrim and white label',
      (tester) async {
        await tester.pumpWidget(
          _wrap(const TagChip(label: 'finance', overlay: true)),
        );

        final chipWidget = tester.widget<Chip>(find.byType(Chip));
        // Slightly darker translucent background (not the washed-out tint).
        expect(chipWidget.backgroundColor, isNotNull);
        expect(chipWidget.backgroundColor!.a, greaterThan(0.35));
        expect(chipWidget.backgroundColor!.a, lessThan(1.0));
        // White label for readability over arbitrary preview content. The chip
        // applies labelStyle internally via DefaultTextStyle, so assert the
        // style passed to the chip.
        expect(chipWidget.labelStyle?.color, Colors.white);
      },
    );
  });
}
