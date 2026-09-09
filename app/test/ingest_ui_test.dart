import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:docean/src/app.dart' show DoceanApp;
import 'package:docean/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docean/src/features/ingest_service.dart'
    show IngestEvent, IngestService;
import 'package:docean/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docean/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docean/src/rust/api/health.dart' show HealthStatus;
import 'package:docean/src/ui/document_view.dart' show DocumentSummary;
import 'package:docean/src/ui/ingest_panel.dart' show IngestPanel;
import 'package:docean/src/ui/search_screen.dart' show SearchScreen;
import 'package:docean/src/features/search_service.dart'
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
    testWidgets('keeps upload UI off the Search tab', (tester) async {
      final search = _FakeSearchService();

      await tester.pumpWidget(
        _wrap(
          SearchScreen(
            searchService: search,
            onOpenDocument: (_) {},
            tags: const [],
          ),
        ),
      );

      // The Search surface is purely a search surface: no drop zone, no
      // "Add files" button, no upload icon.
      expect(find.textContaining('Drop files here'), findsNothing);
      expect(find.text('Add files'), findsNothing);
      expect(find.byIcon(Icons.upload_file), findsNothing);

      // Searching still works.
      await tester.enterText(find.byType(TextField), 'note');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();
      expect(search.queryCount, greaterThan(0));
    });
  });

  group('MainShell ingestion → browse refresh', () {
    testWidgets(
      'uploading from the Documents page adds the file to the browse list '
      'and keeps upload UI off the Search tab',
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
          DoceanApp(
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

        // The app-bar upload icon at the top of the Documents page opens the
        // file picker (evidenced by the fake picker resolving a path).
        await tester.tap(find.byIcon(Icons.upload_file));
        await tester.pumpAndSettle();

        // Ingestion completed: the refresh tick fired, the browse view
        // re-queried SQLite, and the new file is now listed in the grid.
        expect(ingest.calls, hasLength(1));
        expect(ingest.calls.first, contains('/tmp/newfile.txt'));
        expect(
          find.descendant(
            of: find.byType(GridView),
            matching: find.text('newfile.txt'),
          ),
          findsOneWidget,
        );
        // The upload progress strip (with the completed file row) shows on the
        // Documents page, next to the grid.
        expect(find.text('Done'), findsOneWidget);

        // Drag-and-drop + "Add files" now live on the Documents page only:
        // the Search tab carries no upload surface.
        await tester.tap(find.text('Search'));
        await tester.pumpAndSettle();
        expect(find.text('Add files'), findsNothing);
        expect(find.textContaining('Drop files here'), findsNothing);
      },
    );
  });
}

HealthStatus _fakeStatus() => const HealthStatus(
  ok: true,
  engine: 'docean-core',
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
      model: 'docean-tiny',
      enabled: true,
      models: const [],
      hasApiKey: true,
    ),
  ];

  @override
  ActiveProviderInfo activeProvider() => const ActiveProviderInfo(
    kind: 'builtin',
    model: 'docean-tiny',
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
