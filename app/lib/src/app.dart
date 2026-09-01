import 'package:flutter/material.dart';

import 'features/assistant_service.dart'
    show AssistantService, BridgeAssistantService;
import 'features/provider_service.dart'
    show BridgeProviderService, ProviderService;
import 'features/search_service.dart' show BridgeSearchService, SearchService;
import 'p2p_sync_screen.dart';
import 'rust/api/health.dart';
import 'rust_health.dart';
import 'ui/chat_screen.dart' show ChatScreen;
import 'ui/document_view.dart' show DocumentDetailView, DocumentSummary;
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
    this.tags = const [],
    this.paths = const [],
    this.openDocument,
  });

  final HealthCheckFn healthCheck;
  final SearchService searchService;
  final AssistantService assistantService;
  final ProviderService providerService;
  final List<String> tags;
  final List<String> paths;

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
        tags: tags,
        paths: paths,
        openDocument: openDocument,
      ),
    );
  }
}

/// The navigable shell: a navigation rail on wide screens and a bottom
/// navigation bar on narrow screens, hosting Search, Chat, and Providers.
class MainShell extends StatefulWidget {
  const MainShell({
    super.key,
    required this.healthCheck,
    required this.searchService,
    required this.assistantService,
    required this.providerService,
    required this.tags,
    required this.paths,
    this.openDocument,
  });

  final HealthCheckFn healthCheck;
  final SearchService searchService;
  final AssistantService assistantService;
  final ProviderService providerService;
  final List<String> tags;
  final List<String> paths;
  final DocumentOpener? openDocument;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  bool _aiAvailable = true;
  HealthStatus? _status;
  bool _healthError = false;

  @override
  void initState() {
    super.initState();
    _probeAi();
    _probeHealth();
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

    final search = SearchScreen(
      searchService: widget.searchService,
      onOpenDocument: _openDocument,
      tags: widget.tags,
      paths: widget.paths,
      onConfigureAi: () => setState(() => _index = 2),
    );
    final chat = ChatScreen(
      assistantService: widget.assistantService,
      onOpenDocument: _openDocument,
      aiAvailable: _aiAvailable,
      onConfigureAi: () => setState(() => _index = 2),
    );
    final providers = ProviderScreen(providerService: widget.providerService);

    final pages = <Widget>[search, chat, providers];

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
        title: Text(['Search', 'Chat', 'Providers'][_index]),
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
