import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docer/src/app.dart' show DocerApp;
import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/features/ingest_service.dart'
    show IngestEvent, IngestService;
import 'package:docer/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docer/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docer/src/rust/api/health.dart' show HealthStatus;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/ingest_panel.dart' show IngestPanel;
import 'package:docer/src/ui/search_screen.dart' show SearchScreen;
import 'package:docer/src/features/search_service.dart'
    show SearchHitDto, SearchMode, SearchService;

/// A fake ingestion service that records the paths it was asked to ingest and
/// replays a fixed event sequence (no native library involved).
class _RecordingIngestService implements IngestService {
  _RecordingIngestService(this.events);

  final List<IngestEvent> events;
  final List<List<String>> calls = [];

  @override
  Stream<IngestEvent> ingestFiles(List<String> paths) async* {
    calls.add(List.of(paths));
    for (final e in events) {
      yield e;
    }
  }
}

class _FakeSearchService implements SearchService {
  int queryCount = 0;

  @override
  List<SearchHitDto> query(
    String text, {
    required SearchMode mode,
    List<String> tags = const [],
    List<String> paths = const [],
    int? limit,
  }) {
    queryCount++;
    return const [];
  }

  @override
  void indexDocument(String documentId, String text) {}

  @override
  void setMetadata(
    String documentId, {
    List<String> tags = const [],
    List<String> paths = const [],
  }) {}

  @override
  void removeDocument(String documentId) {}
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  group('IngestPanel', () {
    testWidgets('picker triggers ingestion and renders progress events', (
      tester,
    ) async {
      final service = _RecordingIngestService([
        const IngestEvent(
          kind: 'processing',
          fileName: 'report.pdf',
          percent: 0,
          documentId: '',
          error: '',
        ),
        const IngestEvent(
          kind: 'extracting',
          fileName: 'report.pdf',
          percent: 50,
          documentId: '',
          error: '',
        ),
        const IngestEvent(
          kind: 'completed',
          fileName: 'report.pdf',
          percent: 100,
          documentId: 'doc-123',
          error: '',
        ),
      ]);

      await tester.pumpWidget(
        _wrap(
          IngestPanel(
            ingestService: service,
            pickPaths: () async => ['/tmp/report.pdf'],
          ),
        ),
      );

      // The drop zone and fallback button are present.
      expect(find.textContaining('Drop files here'), findsOneWidget);
      expect(find.text('Add files'), findsOneWidget);

      // Tap "Add files" to open the (fake) picker.
      await tester.tap(find.text('Add files'));
      await tester.pumpAndSettle();

      // The service was asked to ingest the picked path.
      expect(service.calls, hasLength(1));
      expect(service.calls.first, contains('/tmp/report.pdf'));

      // The completed file row is rendered with its document id.
      expect(find.text('report.pdf'), findsOneWidget);
      expect(find.text('Done'), findsOneWidget);
      expect(find.text('Document doc-123'), findsOneWidget);
    });

    testWidgets('renders a failed event with its error', (tester) async {
      final service = _RecordingIngestService([
        const IngestEvent(
          kind: 'failed',
          fileName: 'bad.bin',
          percent: 0,
          documentId: '',
          error: 'unsupported file type bin',
        ),
      ]);

      await tester.pumpWidget(
        _wrap(
          IngestPanel(
            ingestService: service,
            pickPaths: () async => ['/tmp/bad.bin'],
          ),
        ),
      );

      await tester.tap(find.text('Add files'));
      await tester.pumpAndSettle();

      expect(find.text('bad.bin'), findsOneWidget);
      expect(find.text('Failed'), findsOneWidget);
      expect(find.text('unsupported file type bin'), findsOneWidget);
    });
  });

  group('SearchScreen integration', () {
    testWidgets('refreshes search results after ingestion completes', (
      tester,
    ) async {
      final ingest = _RecordingIngestService([
        const IngestEvent(
          kind: 'completed',
          fileName: 'note.txt',
          percent: 100,
          documentId: 'doc-9',
          error: '',
        ),
      ]);
      final search = _FakeSearchService();

      await tester.pumpWidget(
        _wrap(
          SearchScreen(
            searchService: search,
            ingestService: ingest,
            onOpenDocument: (_) {},
            tags: const [],
            pickPaths: () async => ['/tmp/note.txt'],
          ),
        ),
      );

      // Run an initial query so there is something to refresh.
      await tester.enterText(find.byType(TextField), 'note');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();
      final before = search.queryCount;
      expect(before, greaterThan(0));

      await tester.tap(find.text('Add files'));
      await tester.pumpAndSettle();

      // The search service was re-queried after ingestion finished.
      expect(search.queryCount, greaterThan(before));
    });
  });

  group('MainShell ingestion → browse refresh', () {
    testWidgets(
      'ingesting a file makes it appear in the Documents browse list',
      (tester) async {
        final ingest = _RecordingIngestService([
          const IngestEvent(
            kind: 'completed',
            fileName: 'newfile.txt',
            percent: 100,
            documentId: 'doc-new',
            error: '',
          ),
        ]);
        // A document service whose listing reflects whatever ingestion has
        // stored, mirroring the real SQLite-backed bridge.
        final docs = _IngestAwareDocumentService(ingest);
        final search = _FakeSearchService();

        await tester.pumpWidget(
          DocerApp(
            healthCheck: _fakeStatus,
            providerService: _FakeProviderService(),
            ingestService: ingest,
            documentService: docs,
            searchService: search,
            pickPaths: () async => ['/tmp/newfile.txt'],
          ),
        );
        await tester.pumpAndSettle();

        // Documents tab is the default; nothing has been ingested yet.
        expect(find.text('No documents yet'), findsOneWidget);

        // Go to the Search tab and ingest a file through the panel.
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('Add files'));
        await tester.pumpAndSettle();

        // Ingestion completed: the refresh tick fired, the browse view
        // re-queried SQLite, and the new file is now listed.
        await tester.tap(find.text('Documents'));
        await tester.pumpAndSettle();
        expect(find.text('newfile.txt'), findsOneWidget);
      },
    );
  });
}

HealthStatus _fakeStatus() => const HealthStatus(
  ok: true,
  engine: 'docer-core',
  engineVersion: '0.1.0',
  platform: 'test',
  timestampMs: 123,
);

/// A minimal provider double so the shell's AI probe stays offline-safe.
class _FakeProviderService implements ProviderService {
  @override
  List<ProviderSettings> listProviders() => [
    ProviderSettings(
      kind: ProviderKind.builtin,
      model: 'docer-tiny',
      enabled: true,
      models: const [],
      hasApiKey: true,
    ),
  ];

  @override
  ActiveProviderInfo activeProvider() => const ActiveProviderInfo(
    kind: 'builtin',
    model: 'docer-tiny',
    baseUrl: null,
    hasApiKey: false,
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

/// A [DocumentService] double whose listing follows what [IngestService] has
/// ingested, mimicking the real SQLite-backed repository visibility.
class _IngestAwareDocumentService extends FakeDocumentService {
  _IngestAwareDocumentService(this.ingest) : super();

  final _RecordingIngestService ingest;

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    listCount++;
    final summaries = super.listDocuments();
    final results = await summaries;
    for (final call in ingest.calls) {
      final basename = call.first.split('/').last;
      if (!results.any((d) => d.title == basename)) {
        results.add(
          DocumentSummary(id: 'doc-${results.length + 1}', title: basename),
        );
      }
    }
    return results;
  }
}
