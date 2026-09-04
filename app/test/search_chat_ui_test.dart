import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:docer/src/features/assistant_service.dart'
    show AssistantChunk, AssistantDone, AssistantService, AssistantTokens;
import 'package:docer/src/features/document_preview.dart'
    show DocumentPreviewLoader;
import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/features/provider_service.dart'
    show ProviderKind, ProviderService, ProviderSettings;
import 'package:docer/src/features/search_service.dart'
    show HighlightSpan, SearchHitDto, SearchMode, SearchService;
import 'package:docer/src/rust/api/ai.dart' show ActiveProviderInfo;
import 'package:docer/src/rust/api/assistant.dart' show DocumentRefDto;
import 'package:docer/src/ui/chat_screen.dart' show ChatScreen;
import 'package:docer/src/ui/document_preview_view.dart'
    show DocumentPlaceholder, DocumentThumbnail;
import 'package:docer/src/ui/document_view.dart' show DocumentSummary;
import 'package:docer/src/ui/provider_screen.dart' show ProviderScreen;
import 'package:docer/src/ui/search_screen.dart' show SearchScreen;

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeSearchService implements SearchService {
  @override
  List<SearchHitDto> query(
    String text, {
    required SearchMode mode,
    List<String> tags = const [],
    List<String> paths = const [],
    int? limit,
  }) {
    if (text.trim().isEmpty) return const [];
    return [
      SearchHitDto(
        documentId: 'doc-1',
        score: 0.9,
        snippet: 'The quick brown fox jumps over the lazy dog.',
        highlights: [HighlightSpan(start: BigInt.from(4), end: BigInt.from(9))],
        tags: const ['finance'],
        paths: const ['/work/reports'],
      ),
    ];
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

class _FakeAssistantService implements AssistantService {
  const _FakeAssistantService(this.chunks);

  final List<AssistantChunk> chunks;

  @override
  Stream<AssistantChunk> ask(String question) async* {
    for (final c in chunks) {
      yield c;
    }
  }

  @override
  void clearHistory() {}
}

class _FakeProviderService implements ProviderService {
  _FakeProviderService({String? activeKind})
    : activeKind = activeKind ?? 'builtin';

  final String activeKind;

  @override
  List<ProviderSettings> listProviders() => [
    ProviderSettings(
      kind: ProviderKind.builtin,
      model: 'docer-tiny',
      enabled: true,
      models: const [],
      hasApiKey: true,
    ),
    ProviderSettings(
      kind: ProviderKind.openai,
      baseUrl: 'https://api.openai.com/v1',
      model: 'gpt-4o-mini',
      enabled: true,
      models: const [],
      hasApiKey: false,
    ),
  ];

  @override
  ActiveProviderInfo activeProvider() => ActiveProviderInfo(
    kind: activeKind,
    model: activeKind == 'builtin' ? 'docer-tiny' : 'gpt-4o-mini',
    baseUrl: activeKind == 'builtin' ? null : 'https://api.openai.com/v1',
    hasApiKey: activeKind != 'builtin',
  );

  @override
  ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      ActiveProviderInfo(
        kind: kind,
        model: model ?? 'gpt-4o-mini',
        baseUrl: 'https://api.openai.com/v1',
        hasApiKey: false,
      );

  @override
  void saveProviderSettings(ProviderSettings settings) {}

  @override
  void setApiKey(String kind, String key) {}

  @override
  void removeApiKey(String kind) {}
}

void main() {
  group('SearchScreen', () {
    testWidgets('runs a query and shows highlighted snippets', (tester) async {
      final opened = <DocumentSummary>[];
      await tester.pumpWidget(
        _wrap(
          SearchScreen(
            searchService: _FakeSearchService(),
            onOpenDocument: opened.add,
            tags: const ['finance', 'tax'],
            paths: const ['/work'],
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'quick fox');
      await tester.tap(find.byIcon(Icons.arrow_forward));
      await tester.pumpAndSettle();

      expect(find.textContaining('quick brown fox'), findsOneWidget);
      // 'finance' and the path appear as filters + on the result card.
      expect(find.text('finance'), findsWidgets);
      expect(find.text('/work/reports'), findsWidgets);

      await tester.tap(find.text('Exact'));
      await tester.pumpAndSettle();
      expect(find.textContaining('quick brown fox'), findsOneWidget);

      await tester.tap(find.textContaining('quick brown fox'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(opened.first.id, 'doc-1');
    });

    testWidgets('shows an empty state before a query', (tester) async {
      await tester.pumpWidget(
        _wrap(
          SearchScreen(
            searchService: _FakeSearchService(),
            onOpenDocument: (_) {},
            tags: const [],
          ),
        ),
      );
      expect(find.textContaining('Type a query'), findsOneWidget);
    });

    testWidgets('tag filters are passed to the service', (tester) async {
      ServiceCall? call;
      final fake = _RecordingSearchService((c) => call = c);
      await tester.pumpWidget(
        _wrap(
          SearchScreen(
            searchService: fake,
            onOpenDocument: (_) {},
            tags: const ['finance', 'tax'],
          ),
        ),
      );
      await tester.enterText(find.byType(TextField), 'report');
      await tester.tap(find.text('finance'));
      await tester.pumpAndSettle();
      expect(call, isNotNull);
      expect(call!.tags, contains('finance'));
    });

    testWidgets(
      'renders an image thumbnail in search results when metadata resolves',
      (tester) async {
        final docs = FakeDocumentService(
          documents: [
            const DocumentSummary(
              id: 'doc-1',
              title: '/work/reports',
              mimeType: 'image/png',
            ),
          ],
          bytesByDocumentId: {
            'doc-1': Uint8List.fromList(
              img.encodePng(img.Image(width: 8, height: 8)),
            ),
          },
        );
        final loader = DocumentPreviewLoader(
          bytesSource: (id) => docs.readBytes(id),
          imageThumbnailer: ({required bytes, required maxDim}) async {
            final decoded = img.decodeImage(bytes);
            if (decoded == null) return null;
            final resized = img.copyResize(
              decoded,
              width: maxDim < decoded.width ? maxDim : decoded.width,
            );
            return Uint8List.fromList(img.encodePng(resized));
          },
          pdfSupport: () async => false,
        );

        await tester.pumpWidget(
          _wrap(
            SearchScreen(
              searchService: _FakeSearchService(),
              onOpenDocument: (_) {},
              tags: const ['finance'],
              documentService: docs,
              previewLoader: loader,
            ),
          ),
        );

        await tester.enterText(find.byType(TextField), 'quick fox');
        await tester.tap(find.byIcon(Icons.arrow_forward));
        await tester.pumpAndSettle();

        // The search hit resolved the MIME via getDocument and now shows a
        // real image thumbnail rather than a placeholder tile.
        expect(find.byType(DocumentThumbnail), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(DocumentThumbnail),
            matching: find.byType(Ink),
          ),
          findsOneWidget,
        );
        expect(find.byType(DocumentPlaceholder), findsNothing);
      },
    );
  });

  group('ChatScreen', () {
    testWidgets('streams tokens and renders clickable citations', (
      tester,
    ) async {
      final opened = <DocumentSummary>[];
      const assistant = _FakeAssistantService([
        AssistantTokens('The answer is '),
        AssistantTokens('42.'),
        AssistantDone([
          DocumentRefDto(documentId: 'ref-1', excerpt: 'See the manual.'),
        ]),
      ]);

      await tester.pumpWidget(
        _wrap(
          ChatScreen(
            assistantService: assistant,
            onOpenDocument: opened.add,
            aiAvailable: true,
          ),
        ),
      );

      await tester.enterText(find.byType(TextField), 'what is the answer');
      await tester.pump();
      await tester.tap(find.byIcon(Icons.send));
      await tester.pump();
      // Let the async stream deliver its tokens.
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('The answer is 42'), findsOneWidget);
      expect(find.text('Sources'), findsOneWidget);
      expect(find.text('ref-1'), findsOneWidget);

      await tester.tap(find.text('ref-1'));
      await tester.pumpAndSettle();
      expect(opened, hasLength(1));
      expect(opened.first.id, 'ref-1');
    });

    testWidgets('shows a degraded banner when AI is unavailable', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          ChatScreen(
            assistantService: _FakeAssistantService(const []),
            onOpenDocument: (_) {},
            aiAvailable: false,
            onConfigureAi: () {},
          ),
        ),
      );
      expect(
        find.textContaining('No AI provider is configured'),
        findsOneWidget,
      );
    });
  });
  group('ProviderScreen', () {
    testWidgets('lists providers and marks the active one', (tester) async {
      await tester.pumpWidget(
        _wrap(ProviderScreen(providerService: _FakeProviderService())),
      );
      await tester.pumpAndSettle();

      expect(find.text('Built-in (local)'), findsOneWidget);
      expect(find.text('OpenAI-compatible'), findsOneWidget);
      expect(find.text('Active'), findsOneWidget);
    });

    testWidgets('lets you save a provider', (tester) async {
      await tester.pumpWidget(
        _wrap(ProviderScreen(providerService: _FakeProviderService())),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('OpenAI-compatible'));
      await tester.pumpAndSettle();

      expect(find.text('Configure OpenAI-compatible'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);

      await tester.enterText(find.byType(TextField).first, 'gpt-4o');
      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      await tester.pumpAndSettle();
      expect(find.textContaining('saved'), findsOneWidget);
    });

    testWidgets('degrades gracefully when the service fails', (tester) async {
      await tester.pumpWidget(
        _wrap(ProviderScreen(providerService: _FailingProviderService())),
      );
      await tester.pumpAndSettle();

      expect(
        find.textContaining('Provider configuration unavailable'),
        findsOneWidget,
      );
    });
  });
}

class ServiceCall {
  ServiceCall(this.tags);

  final List<String> tags;
}

class _RecordingSearchService implements SearchService {
  _RecordingSearchService(this.onCall);

  final void Function(ServiceCall call) onCall;

  @override
  List<SearchHitDto> query(
    String text, {
    required SearchMode mode,
    List<String> tags = const [],
    List<String> paths = const [],
    int? limit,
  }) {
    onCall(ServiceCall(tags));
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

class _FailingProviderService implements ProviderService {
  @override
  List<ProviderSettings> listProviders() =>
      throw StateError('engine unavailable');

  @override
  ActiveProviderInfo activeProvider() => throw StateError('engine unavailable');

  @override
  ActiveProviderInfo selectProvider(String kind, {String? model}) =>
      throw StateError('engine unavailable');

  @override
  void saveProviderSettings(ProviderSettings settings) {}

  @override
  void setApiKey(String kind, String key) {}

  @override
  void removeApiKey(String kind) {}
}

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));
