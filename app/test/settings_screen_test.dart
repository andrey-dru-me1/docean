import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService, ReorganizeResult;
import 'package:docer/src/ui/settings_screen.dart' show SettingsScreen;

Widget _wrap(Widget child) => MaterialApp(home: child);

void main() {
  group('SettingsScreen', () {
    testWidgets('renders the re-organize button and offline note', (
      tester,
    ) async {
      final service = FakeDocumentService();
      await tester.pumpWidget(_wrap(SettingsScreen(documentService: service)));
      await tester.pumpAndSettle();

      expect(find.text('Settings'), findsOneWidget);
      expect(find.text('Re-organize all documents'), findsOneWidget);
      expect(find.textContaining('no AI provider required'), findsOneWidget);
      expect(find.text('Organization complete'), findsNothing);
    });

    testWidgets('tapping re-organize calls the service and shows the summary', (
      tester,
    ) async {
      final service = FakeDocumentService()
        ..reorganizeResult = const ReorganizeResult(
          total: 24,
          updated: 9,
          skipped: 15,
        );
      await tester.pumpWidget(_wrap(SettingsScreen(documentService: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Re-organize all documents'));
      await tester.pumpAndSettle();

      expect(service.reorganizeAllCount, 1);
      expect(find.text('Organization complete'), findsOneWidget);
      expect(find.text('Documents examined'), findsOneWidget);
      expect(find.text('24'), findsOneWidget);
      expect(find.text('Updated'), findsOneWidget);
      expect(find.text('9'), findsOneWidget);
      expect(find.text('Skipped (manual edits / no change)'), findsOneWidget);
      expect(find.text('15'), findsOneWidget);
    });

    testWidgets('shows an error when the re-organize pass fails', (
      tester,
    ) async {
      final service = _FailingReorganizeService();
      await tester.pumpWidget(_wrap(SettingsScreen(documentService: service)));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Re-organize all documents'));
      await tester.pumpAndSettle();

      expect(find.textContaining('Could not re-organize'), findsOneWidget);
      expect(find.text('Organization complete'), findsNothing);
      // The button is usable again after the failure.
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });
  });
}

/// A [FakeDocumentService] whose bulk re-organization always fails.
class _FailingReorganizeService extends FakeDocumentService {
  @override
  Future<ReorganizeResult> reorganizeAll() async =>
      throw StateError('repository unavailable');
}
