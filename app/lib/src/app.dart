import 'package:flutter/material.dart';

import 'features/assistant_service.dart'
    show AssistantService, BridgeAssistantService;
import 'features/document_service.dart'
    show BridgeDocumentService, DoceanBulkOrganizer, DocumentService;
import 'features/ingest_service.dart' show BridgeIngestService, IngestService;
import 'features/library_directory.dart'
    show
        BridgeLibraryDirectoryService,
        InMemoryLibraryDirectoryService,
        LibraryDirectoryService;
import 'features/provider_service.dart'
    show BridgeProviderService, ProviderService;
import 'features/search_service.dart' show BridgeSearchService, SearchService;
import 'p2p_sync_screen.dart';
import 'rust/api/health.dart';
import 'rust_health.dart';
import 'ui/chat_screen.dart' show ChatScreen;
import 'ui/document_view.dart' show DocumentDetailView, DocumentSummary;
import 'ui/documents_screen.dart' show DocumentsScreen;
import 'ui/documents_upload_page.dart' show DocumentsUploadPage;
import 'ui/ingest_panel.dart'
    show IngestPanelState, PathPicker, pickPathsWithFilePicker;
import 'ui/learning_panel.dart' show LearningPanel;
import 'ui/library_folder_dialog.dart'
    show DirectoryPicker, pickDirectoryWithFilePicker, showLibraryFolderDialog;
import 'ui/provider_screen.dart' show ProviderScreen;
import 'ui/search_screen.dart' show DocumentOpener, SearchScreen;

/// Root widget. All services are injectable so widget tests can run headlessly
/// without the native library; the app uses the bridge-backed defaults.
class DoceanApp extends StatelessWidget {
  const DoceanApp({
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
    this.libraryService = const BridgeLibraryDirectoryService(),
    this.pickDirectory,
    this.libraryBookmarkFolder,
    this.libraryScopeRestore,
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

  /// Injectable library-folder service. Defaults to the bridge-backed
  /// implementation; tests inject their own fakes so they never touch the
  /// native library.
  final LibraryDirectoryService? libraryService;

  /// Injected directory picker for the library-folder dialog (defaults to the
  /// native `file_picker`); tests inject a fake.
  final DirectoryPicker? pickDirectory;

  /// Persists the App Sandbox security-scoped bookmark for a freshly picked
  /// library folder. Production wires the platform channel; tests leave it
  /// `null` so picker flows never touch the channel.
  final Future<bool> Function(String path)? libraryBookmarkFolder;

  /// Restores a persisted security-scoped access at startup. `null` in tests.
  final Future<String?> Function()? libraryScopeRestore;

  @override
  Widget build(BuildContext context) {
    final baseScheme = ColorScheme.fromSeed(seedColor: Colors.teal);
    final darkScheme = ColorScheme.fromSeed(
      seedColor: Colors.teal,
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'Docean',
      debugShowCheckedModeBanner: false,
      theme: _themeFor(baseScheme),
      darkTheme: _themeFor(darkScheme),
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
        libraryService: libraryService,
        pickDirectory: pickDirectory,
        libraryBookmarkFolder: libraryBookmarkFolder,
        libraryScopeRestore: libraryScopeRestore,
      ),
    );
  }
}

/// Builds the app [ThemeData] for a given color scheme (light or dark).
///
/// Kept as one helper so light and dark modes stay visually identical: dense
/// desktop-first metrics, and — critically — *explicit* text colors derived
/// from the scheme. The framework's chip/AppBar defaults can resolve label and
/// title text to `onPrimary`-style light colors even on light surfaces, which
/// renders as white-on-light; pinning `onSurface`/`onSurfaceVariant` here
/// keeps every title/chip label dark-on-light in light mode and light-on-dark
/// in dark mode.
ThemeData _themeFor(ColorScheme scheme) {
  return ThemeData(
    colorScheme: scheme,
    useMaterial3: true,
    // Dense desktop-first layout: compact everything so more documents and
    // metadata fit on screen at once while mobile stays usable.
    visualDensity: VisualDensity.compact,
    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
    appBarTheme: AppBarTheme(
      toolbarHeight: 44,
      foregroundColor: scheme.onSurface,
      titleTextStyle: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: scheme.onSurface,
      ),
    ),
    chipTheme: ChipThemeData(
      labelPadding: const EdgeInsets.symmetric(horizontal: 4),
      padding: const EdgeInsets.symmetric(horizontal: 6),
      labelStyle: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
      secondaryLabelStyle: TextStyle(
        fontSize: 11.5,
        color: scheme.onSurfaceVariant,
      ),
    ),
    inputDecorationTheme: const InputDecorationTheme(
      isDense: true,
      contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 8),
    ),
    cardTheme: CardThemeData(margin: EdgeInsets.zero, elevation: 1),
    listTileTheme: const ListTileThemeData(
      visualDensity: VisualDensity.compact,
      minVerticalPadding: 2,
    ),
    navigationBarTheme: const NavigationBarThemeData(
      labelBehavior: NavigationDestinationLabelBehavior.onlyShowSelected,
    ),
  );
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
    this.libraryService,
    this.pickDirectory,
    this.libraryBookmarkFolder,
    this.libraryScopeRestore,
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
  final LibraryDirectoryService? libraryService;
  final DirectoryPicker? pickDirectory;

  /// Persists the App Sandbox security-scoped bookmark for a picked library
  /// folder; `null` in tests.
  final Future<bool> Function(String path)? libraryBookmarkFolder;

  /// Restores a persisted security-scoped access at startup; `null` in tests.
  final Future<String?> Function()? libraryScopeRestore;

  @override
  State<MainShell> createState() => _MainShellState();
}

class _MainShellState extends State<MainShell> {
  int _index = 0;
  bool _aiAvailable = true;
  HealthStatus? _status;
  bool _healthError = false;

  late final LibraryDirectoryService _libraryService =
      widget.libraryService ?? InMemoryLibraryDirectoryService();

  /// The document shown in the wide-screen right-side detail panel (master-
  /// detail). `null` renders an empty placeholder.
  DocumentSummary? _selectedDocument;

  /// Bumped when ingestion finishes so the Documents browse tab reloads.
  final ValueNotifier<int> _documentsRefreshTick = ValueNotifier<int>(0);

  /// Reaches the shared ingestion panel hosted on the Documents page, so the
  /// app-bar "Upload files" action can open the file picker from anywhere.
  final GlobalKey<IngestPanelState> _ingestPanelKey =
      GlobalKey<IngestPanelState>();

  @override
  void initState() {
    super.initState();
    _probeAi();
    _probeHealth();
    // Rebuild the in-memory search index from the persisted repository so
    // documents from previous sessions are searchable immediately.
    _reindexSearch();
    _documentsRefreshTick.addListener(_checkSidebarDocument);
    WidgetsBinding.instance.addPostFrameCallback((_) => _autoSyncLibrary());
  }

  @override
  void dispose() {
    _documentsRefreshTick.removeListener(_checkSidebarDocument);
    _documentsRefreshTick.dispose();
    super.dispose();
  }

  /// When the document list refreshes, verify the selected sidebar document
  /// still exists; close the panel if it was deleted.
  void _checkSidebarDocument() async {
    if (_selectedDocument == null) return;
    try {
      await widget.documentService.getDocument(_selectedDocument!.id);
    } catch (_) {
      if (mounted) setState(() => _selectedDocument = null);
    }
  }

  /// Best-effort startup re-index of the in-memory engine from SQLite. Fails
  /// quietly (e.g. the repository is not open yet in tests / headless shell).
  void _reindexSearch() {
    widget.documentService.reindex().catchError((Object _) {});
  }

  /// Best-effort startup sync: if a library directory is already configured,
  /// run one sync and bump the document list — never block or surface errors.
  /// Restores the App Sandbox security scope first: a picked library folder is
  /// only reachable while its persisted bookmark-backed access is active.
  Future<void> _autoSyncLibrary() async {
    try {
      await widget.libraryScopeRestore?.call();
      final dir = await _libraryService.libraryDirectory();
      if (dir == null) return;
      await _libraryService.syncLibrary();
      if (mounted) _documentsRefreshTick.value++;
    } catch (_) {
      // Startup sync is best-effort: never surface errors.
    }
  }

  /// Opens the library-folder dialog and bumps the refresh tick when the
  /// user changes the folder.
  Future<void> _openLibraryFolder() async {
    final changed = await showLibraryFolderDialog(
      context,
      service: _libraryService,
      pickDirectory: widget.pickDirectory ?? pickDirectoryWithFilePicker,
      bookmarkFolder: widget.libraryBookmarkFolder,
    );
    if (changed == true && mounted) {
      _documentsRefreshTick.value++;
    }
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
    // Wide screens get a master-detail two-pane layout: the detail view is
    // rendered in a right-side panel instead of pushing a new route.
    if (_isWide()) {
      setState(() => _selectedDocument = doc);
      return;
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DocumentDetailView(
          document: doc,
          documentService: widget.documentService,
          onBack: () => Navigator.of(context).pop(),
          onMetaChanged: () => _documentsRefreshTick.value++,
        ),
      ),
    );
  }

  /// Whether we're in the wide (master-detail) mode. Mirrors the existing
  /// `wide` check in [MainShell.build] (width >= 900).
  bool _isWide() {
    final contextSafe = context;
    if (!contextSafe.mounted) return false;
    return MediaQuery.sizeOf(context).width >= 900;
  }

  /// Opens the P2P & Sync screen (kept from the main UI shell integration).
  void _openP2p() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const P2pSyncScreen()));
  }

  /// The app-bar "Upload files" action. The shared ingestion panel lives on the
  /// Documents page; in the wide layout the other tabs are not mounted, so when
  /// it isn't available we switch to Documents and open the picker once the
  /// panel has mounted next frame.
  void _uploadFromAppBar() {
    final panel = _ingestPanelKey.currentState;
    if (panel != null) {
      panel.openPicker();
      return;
    }
    setState(() => _index = 0);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ingestPanelKey.currentState?.openPicker();
    });
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
          // Explicit scheme-derived color (dark-on-light in light mode,
          // light-on-dark in dark mode) instead of the theme's light default.
          labelStyle: TextStyle(
            fontSize: 11.5,
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }

    final documents = DocumentsUploadPage(
      ingestPanelKey: _ingestPanelKey,
      ingestService: widget.ingestService,
      pickPaths: widget.pickPaths ?? pickPathsWithFilePicker,
      onFilesIngested: () => _documentsRefreshTick.value++,
      // Only the visible Documents tab is a drop target: an offstage copy must
      // never swallow drops meant for the tab the user is actually looking at.
      enabled: _index == 0,
      child: DocumentsScreen(
        documentService: widget.documentService,
        onOpenDocument: _openDocument,
        refreshTick: _documentsRefreshTick,
        // The selection toolbar owns the bulk "Re-organize all documents" action
        // (formerly on the Settings screen). Wire the production bridge-backed
        // organizer so the toolbar action actually runs the deterministic pass.
        bulkOrganizer: const DoceanBulkOrganizer(),
      ),
    );
    final search = SearchScreen(
      searchService: widget.searchService,
      onOpenDocument: _openDocument,
      documentService: widget.documentService,
      tags: widget.tags,
      paths: widget.paths,
      onConfigureAi: () => setState(() => _index = 3),
    );
    final chat = ChatScreen(
      assistantService: widget.assistantService,
      onOpenDocument: _openDocument,
      aiAvailable: _aiAvailable,
      onConfigureAi: () => setState(() => _index = 3),
    );
    final providers = ProviderScreen(
      providerService: widget.providerService,
      extraPanel: LearningPanel(documentService: widget.documentService),
    );

    final pages = <Widget>[documents, search, chat, providers];

    if (wide) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Docean'),
          actions: [
            IconButton(
              key: const ValueKey('library-folder'),
              tooltip: 'Library folder',
              onPressed: _openLibraryFolder,
              icon: const Icon(Icons.folder_copy_outlined),
            ),
            IconButton(
              key: const ValueKey('upload-files'),
              tooltip: 'Upload files',
              onPressed: _uploadFromAppBar,
              icon: const Icon(Icons.upload_file),
            ),
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
            // Master-detail two-pane layout: the selected document's info/
            // detail is shown alongside the list instead of a new route.
            //
            // An AnimatedSwitcher + AnimatedSize pair animates the panel's
            // appearance/disappearance (fade+slide in, slide out) instead of
            // the panel popping in/out instantly when a document is selected
            // or the panel is closed.
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              alignment: Alignment.centerLeft,
              child: AnimatedSwitcher(
                key: const ValueKey('detail-panel-switcher'),
                duration: const Duration(milliseconds: 200),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                transitionBuilder: (child, animation) => SlideTransition(
                  position:
                      Tween<Offset>(
                        begin: const Offset(1, 0),
                        end: Offset.zero,
                      ).animate(
                        CurvedAnimation(
                          parent: animation,
                          curve: Curves.easeOut,
                        ),
                      ),
                  child: FadeTransition(opacity: animation, child: child),
                ),
                child: _selectedDocument == null
                    ? const SizedBox.shrink(key: ValueKey('no-selection'))
                    : SizedBox(
                        key: ValueKey(_selectedDocument!.id),
                        width: 420,
                        child: DocumentDetailView(
                          document: _selectedDocument!,
                          documentService: widget.documentService,
                          onBack: () =>
                              setState(() => _selectedDocument = null),
                          onMetaChanged: () => _documentsRefreshTick.value++,
                        ),
                      ),
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(['Documents', 'Search', 'Chat', 'Providers'][_index]),
        actions: [
          IconButton(
            key: const ValueKey('library-folder'),
            tooltip: 'Library folder',
            onPressed: _openLibraryFolder,
            icon: const Icon(Icons.folder_copy_outlined),
          ),
          IconButton(
            key: const ValueKey('upload-files'),
            tooltip: 'Upload files',
            onPressed: _uploadFromAppBar,
            icon: const Icon(Icons.upload_file),
          ),
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
