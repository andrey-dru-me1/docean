import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docer/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docer/src/rust/api/health.dart';

HealthStatus _fakeStatus() => const HealthStatus(
  ok: true,
  engine: 'docer-core',
  engineVersion: '0.1.0',
  platform: 'test',
  timestampMs: 123,
);

/// A test double for [ProviderService] that reports an Ollama (external)
/// provider so no FFI calls are made and the AI path is available.
class _FakeProviderService implements ProviderService {
  @override
  List<ProviderSettings> listProviders() => [
    ProviderSettings(
      kind: ProviderKind.ollama,
      baseUrl: 'http://127.0.0.1:11434',
      model: 'llama3.2',
      enabled: true,
      models: const [],
      hasApiKey: true,
    ),
  ];

  @override
  ActiveProviderInfo activeProvider() => const ActiveProviderInfo(
    kind: 'ollama',
    model: 'llama3.2',
    baseUrl: 'http://127.0.0.1:11434',
    hasApiKey: true,
  );

  @override
  ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      activeProvider();

  @override
  void saveProviderSettings(ProviderSettings settings) {}

  @override
  void setApiKey(String kind, String key) {}

  @override
  void removeApiKey(String kind) {}
}

void main() {
  testWidgets('shows the engine health check chip in the shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Engine OK'), findsOneWidget);
  });

  testWidgets('surfaces a failing health check', (WidgetTester tester) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: () => throw StateError('engine unavailable'),
        providerService: _FakeProviderService(),
      ),
    );
    await tester.pump();

    expect(find.textContaining('Engine degraded'), findsOneWidget);
  });
}
