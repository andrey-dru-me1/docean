import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/rust/api/health.dart';

HealthStatus _fakeStatus() => const HealthStatus(
  ok: true,
  engine: 'docer-core',
  engineVersion: '0.1.0',
  platform: 'test',
  timestampMs: 123,
);

void main() {
  testWidgets('shows the Rust health check result', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(DocerApp(healthCheck: _fakeStatus));
    await tester.pump();

    expect(find.textContaining('Rust core: OK'), findsOneWidget);
    expect(find.textContaining('docer-core v0.1.0 on test'), findsOneWidget);
  });

  testWidgets('surfaces a failing health check', (WidgetTester tester) async {
    await tester.pumpWidget(
      DocerApp(healthCheck: () => throw StateError('engine unavailable')),
    );
    await tester.pump();

    expect(find.textContaining('Engine error'), findsOneWidget);
  });
}
