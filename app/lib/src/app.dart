import 'package:flutter/material.dart';

import 'features/assistant_service.dart'
    show AssistantService, BridgeAssistantService;
import 'features/document_service.dart'
    show BridgeDocumentService, DocumentService;
import 'features/ingest_service.dart' show BridgeIngestService, IngestService;
import 'features/provider_service.dart'
    show BridgeProviderService, ProviderService;
import 'features/search_service.dart' show BridgeSearchService, SearchService;
import 'p2p_sync_screen.dart';
import 'rust/api/health.dart';
import 'rust_health.dart';
import 'ui/chat_screen.dart' show ChatScreen;
import 'ui/document_view.dart' show DocumentDetailView, DocumentSummary;
import 'ui/documents_screen.dart' show DocumentsScreen;
import 'ui/ingest_panel.dart' show PathPicker;
import 'ui/provider_screen.dart' show ProviderScreen;
import 'ui/search_screen.dart' show DocumentOpener, SearchScreen;

/// Root widget. All services are injectable so widget tests can run headlessly
/// without the native library; the app uses the bridge-backed defaults.
class DocerApp extends StatelessWidget {
  const DocerApp({
    super.key,
    this.healthCheck = defaultHealthCheck,
    this.searchService = const BridgeSearchService(),
    this.assistantService = const BridgeAssistantService(),
    this.providerService = const BridgeProviderService(),
    this.ingestService = const BridgeIngestService(),
    this.documentService = const BridgeDocumentService(),
    this.tags = const [],
    this.paths = const [],
    this.pickPaths,
    this.openDocument,
  });

  final HealthCheckFn healthCheck;
  final SearchService searchService;
  final AssistantService assistantService;
  final ProviderService providerService;
  final IngestService ingestService;
  final DocumentService documentService;
  final List<String> tags;
  final List<String> paths;

  /// Injected file picker for the ingestion panel (defaults to the native
  /// `file_picker`); tests inject a fake.
  final PathPicker? pickPaths;

  /// Opens a document from a search result or citation. Defaults to a local
  /// detail view.
  final DocumentOpener? openDocument;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Docer',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        useMaterial3: true,
      ),
      home: MainShell(
        healthCheck: healthCheck,
        searchService: searchService,
        assistantService: assistantService,
        providerService: providerService,
        ingestService: ingestService,
        documentService: documentService,
        tags: tags,
        paths: paths,
        pickPaths: pickPaths,
        openDocument: openDocument,
      ),
    );
  }
}

/// The navigable shell: a navigation rail on wide screens and a bottom
/// navigation bar on narrow screens, hosting Documents, Search, Chat, and
/// Providers.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.healthCheck,
    required this.searchService,
    required this.assistantService,
    required this.providerService,
    required this.ingestService,
    required this.documentService,
    required this.tags,
    required this.paths,
    this.pickPaths,
    this.openDocument,
  });

  final HealthCheckFn healthCheck;
  final SearchService searchService;
  final AssistantService assistantService;
  final ProviderService providerService;
  final IngestService ingestService;
  final DocumentService documentService;
  final List<String> tags;
  final List<String> paths;
  final PathPicker? pickPaths;
  final DocumentOpener? openDocument;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  bool _aiAvailable = true;
  HealthStatus? _status;
  bool _healthError = false;

  /// Bumped when ingestion finishes so the Documents browse tab reloads.
  final ValueNotifier<int> _documentsRefreshTick = ValueNotifier<int>(0);

  @override
  void initState() {
    super.initState();
    _probeAi();
    _probeHealth();
    // Rebuild the in-memory search index from the persisted repository so
    // documents from previous sessions are searchable immediately.
    _reindexSearch();
  }

  @override
  void dispose() {
    _documentsRefreshTick.dispose();
    super.dispose();
  }

  /// Best-effort startup re-index of the in-memory engine from SQLite. Fails
  /// quietly (e.g. the repository is not open yet in tests / headless shell).
  void _reindexSearch() {
    widget.documentService.reindex().catchError((Object _) {});
  }

  void _probeHealth() {
    try {
      _status = widget.healthCheck();
      _healthError = false;
    } catch (_) {
      _status = null;
      _healthError = true;
    }
  }

  void _probeAi() {
    try {
      final active = widget.providerService.activeProvider();
      // The built-in local provider has no API key and serves excerpts only;
      // generative answers require an external (or Ollama) provider.
      _aiAvailable = active.kind != 'builtin';
    } catch (_) {
      _aiAvailable = false;
    }
  }

  void _openDocument(DocumentSummary doc) {
    if (widget.openDocument != null) {
      widget.openDocument!(doc);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DocumentDetailView(
          document: doc,
          documentService: widget.documentService,
          onBack: () => Navigator.of(context).pop(),
        ),
      ),
    );
  }

  /// Opens the P2P & Sync screen (kept from the main UI shell integration).
  void _openP2p() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const P2pSyncScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width >= 900;

    Widget? healthChip;
    final ok = _status?.ok ?? false;
    if (_status != null || _healthError) {
      healthChip = Padding(
        padding: const EdgeInsets.only(right: 16),
        child: Chip(
          avatar: Icon(
            ok ? Icons.check_circle : Icons.warning,
            size: 18,
            color: ok ? Colors.green : Colors.orange,
          ),
          label: Text(ok ? 'Engine OK' : 'Engine degraded'),
        ),
      );
    }

    final documents = DocumentsScreen(
      documentService: widget.documentService,
      onOpenDocument: _openDocument,
      refreshTick: _documentsRefreshTick,
    );
    final search = SearchScreen(
      searchService: widget.searchService,
      ingestService: widget.ingestService,
      onOpenDocument: _openDocument,
      tags: widget.tags,
      paths: widget.paths,
      pickPaths: widget.pickPaths,
      onConfigureAi: () => setState(() => _index = 3),
      onFilesIngested: () => _documentsRefreshTick.value++,
    );
    final chat = ChatScreen(
      assistantService: widget.assistantService,
      onOpenDocument: _openDocument,
      aiAvailable: _aiAvailable,
      onConfigureAi: () => setState(() => _index = 3),
    );
    final providers = ProviderScreen(providerService: widget.providerService);

    final pages = <Widget>[documents, search, chat, providers];

    if (wide) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Docer'),
          actions: [
            IconButton(
              tooltip: 'P2P & Sync',
              onPressed: _openP2p,
              icon: const Icon(Icons.swap_horiz),
            ),
            ?healthChip,
          ],
        ),
        body: Row(
          children: [
            NavigationRail(
              selectedIndex: _index,
              onDestinationSelected: (i) => setState(() => _index = i),
              labelType: NavigationRailLabelType.all,
              destinations: const [
                NavigationRailDestination(
                  icon: Icon(Icons.folder_open),
                  selectedIcon: Icon(Icons.folder),
                  label: Text('Documents'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.search),
                  label: Text('Search'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.chat_bubble_outline),
                  selectedIcon: Icon(Icons.chat_bubble),
                  label: Text('Chat'),
                ),
                NavigationRailDestination(
                  icon: Icon(Icons.tune),
                  label: Text('Providers'),
                ),
              ],
            ),
            const VerticalDivider(width: 1),
            Expanded(child: pages[_index]),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(['Documents', 'Search', 'Chat', 'Providers'][_index]),
        actions: [
          IconButton(
            tooltip: 'P2P & Sync',
            onPressed: _openP2p,
            icon: const Icon(Icons.swap_horiz),
          ),
          ?healthChip,
        ],
      ),
      body: IndexedStack(index: _index, children: pages),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.folder_open),
            selectedIcon: Icon(Icons.folder),
            label: 'Documents',
          ),
          NavigationDestination(icon: Icon(Icons.search), label: 'Search'),
          NavigationDestination(
            icon: Icon(Icons.chat_bubble_outline),
            selectedIcon: Icon(Icons.chat_bubble),
            label: 'Chat',
          ),
          NavigationDestination(icon: Icon(Icons.tune), label: 'Providers'),
        ],
      ),
    );
  }
}
