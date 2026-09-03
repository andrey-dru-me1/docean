import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/app.dart';
import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docer/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docer/src/rust/api/health.dart';
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;

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
  testWidgets('app shell text is dark-on-light in light mode', (tester) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: FakeDocumentService(),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.text('Engine OK'));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.light);
    // Chip labels (Engine OK, path chips) resolve to the readable dark
    // onSurfaceVariant instead of a light-on-light default.
    expect(
      theme.chipTheme.labelStyle?.color,
      theme.colorScheme.onSurfaceVariant,
    );
    expect(
      theme.chipTheme.labelStyle!.color!.computeLuminance(),
      lessThan(0.5),
    );
    // The AppBar title uses onSurface (dark in light mode).
    expect(
      theme.appBarTheme.titleTextStyle?.color,
      theme.colorScheme.onSurface,
    );
    expect(
      theme.appBarTheme.titleTextStyle!.color!.computeLuminance(),
      lessThan(0.5),
    );
  });

  testWidgets('app shell text is light-on-dark in dark mode', (tester) async {
    final platformDispatcher = tester.binding.platformDispatcher;
    platformDispatcher.platformBrightnessTestValue = Brightness.dark;
    addTearDown(platformDispatcher.clearPlatformBrightnessTestValue);

    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: FakeDocumentService(),
      ),
    );
    await tester.pumpAndSettle();

    final context = tester.element(find.text('Engine OK'));
    final theme = Theme.of(context);
    expect(theme.brightness, Brightness.dark);
    // Both chip labels and the AppBar title flip to light-on-dark.
    expect(
      theme.chipTheme.labelStyle?.color,
      theme.colorScheme.onSurfaceVariant,
    );
    expect(
      theme.chipTheme.labelStyle!.color!.computeLuminance(),
      greaterThan(0.5),
    );
    expect(
      theme.appBarTheme.titleTextStyle?.color,
      theme.colorScheme.onSurface,
    );
    expect(
      theme.appBarTheme.titleTextStyle!.color!.computeLuminance(),
      greaterThan(0.5),
    );
  });

  testWidgets('shows the engine health check chip in the shell', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: FakeDocumentService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Engine OK'), findsOneWidget);
  });

  testWidgets('surfaces a failing health check', (WidgetTester tester) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: () => throw StateError('engine unavailable'),
        providerService: _FakeProviderService(),
        documentService: FakeDocumentService(),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('Engine degraded'), findsOneWidget);
  });

  testWidgets('reindexes the search index from persisted docs on startup', (
    WidgetTester tester,
  ) async {
    final docs = FakeDocumentService();
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: docs,
      ),
    );
    await tester.pumpAndSettle();

    // The shell requests the index rebuild once during init so documents from
    // previous sessions are searchable after a restart.
    expect(docs.reindexCount, greaterThanOrEqualTo(1));
  });

  testWidgets('Documents is the first navigation destination', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: FakeDocumentService(),
      ),
    );
    await tester.pumpAndSettle();

    // Browse surface is wired into the shell.
    expect(find.text('Documents'), findsWidgets);
    expect(find.text('No documents yet'), findsOneWidget);

    // Navigating to Search is still possible.
    await tester.tap(find.text('Search'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Type a query'), findsOneWidget);
  });

  testWidgets(
    'wide screens show the document detail in a right-side panel instead of '
    'pushing a route',
    (tester) async {
      final docs = FakeDocumentService(
        documents: [const DocumentSummary(id: 'doc-1', title: 'Wide report')],
        contentByDocumentId: const {'doc-1': 'Body of the wide report.'},
      );

      // A >= 900px wide viewport triggers the master-detail layout.
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        DocerApp(
          healthCheck: _fakeStatus,
          providerService: _FakeProviderService(),
          documentService: docs,
        ),
      );
      await tester.pumpAndSettle();

      // The Documents list is present.
      expect(find.text('Wide report'), findsOneWidget);

      // Tapping opens the detail inline (no new route).
      await tester.tap(find.text('Wide report'));

      // The panel animates in via AnimatedSwitcher/AnimatedSize: it must not
      // already be fully laid out on the very first frame after the tap.
      await tester.pump();
      final switcher = tester.widget<AnimatedSwitcher>(
        find.byKey(const ValueKey('detail-panel-switcher')),
      );
      expect(switcher.duration, const Duration(milliseconds: 200));
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is AnimatedSize &&
              w.duration == const Duration(milliseconds: 200),
        ),
        findsOneWidget,
      );
      await tester.pumpAndSettle();

      // The detail panel is rendered alongside the list.
      expect(find.byTooltip('Suggest tags'), findsOneWidget);
      expect(find.textContaining('Body of the wide report'), findsOneWidget);

      // Closing the panel dismisses it (after the exit transition completes).
      await tester.tap(find.byIcon(Icons.arrow_back));
      await tester.pump();
      expect(find.byTooltip('Suggest tags'), findsOneWidget);
      await tester.pumpAndSettle();
      expect(find.byTooltip('Suggest tags'), findsNothing);
    },
  );

  testWidgets('the Documents tab exposes the bulk-select toolbar', (
    WidgetTester tester,
  ) async {
    final docs = FakeDocumentService(
      documents: [
        const DocumentSummary(id: 'doc-1', title: 'Selectable report'),
      ],
    );
    await tester.pumpWidget(
      DocerApp(
        healthCheck: _fakeStatus,
        providerService: _FakeProviderService(),
        documentService: docs,
      ),
    );
    await tester.pumpAndSettle();

    // The Documents surface is shown by default with the selection affordance.
    expect(find.text('Selectable report'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('select-documents')));
    await tester.pumpAndSettle();

    // 'Select all' enters selection mode with every filtered document already
    // selected (mirrors DocumentsScreen._selectAllFiltered + the dedicated
    // documents_browse_test.dart expectations).
    expect(find.byKey(const ValueKey('selection-bar')), findsOneWidget);
    expect(find.text('1 selected'), findsOneWidget);
    expect(find.byKey(const ValueKey('select-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('bulk-reorganize')), findsOneWidget);
  });
}
