import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart' show DocumentService;
import 'document_preview_view.dart' show DocumentTilePreview;
import 'document_view.dart' show DocumentSummary;
import 'search_screen.dart' show DocumentOpener;
import 'widgets.dart' show EmptyState, TagChip, tagColorFor, tagTintFor;

/// The Documents browse/list surface.
///
/// Lists every document persisted in the SQLite repository (through
/// [`DocumentService.listDocuments`]), regardless of whether the in-memory
/// search index has seen it — so uploaded files are always visible even before
/// they become searchable. Supports client-side filtering by title, tag, and
/// hierarchy path.
class DocumentsScreen extends StatefulWidget {
  const DocumentsScreen({
    super.key,
    required this.documentService,
    required this.onOpenDocument,
    this.refreshTick,
    this.previewLoader,
  });

  final DocumentService documentService;
  final DocumentOpener onOpenDocument;

  /// An optional `ValueNotifier` bumped to signal "something may have changed"
  /// (e.g. ingestion completed), causing the list to reload.
  final ValueListenable<int>? refreshTick;

  /// The preview loader for list thumbnails. Defaults to a loader bound to
  /// [documentService]; injectable so widget tests can swap in a synchronous
  /// (isolate-free) thumbnailer.
  final DocumentPreviewLoader? previewLoader;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<DocumentSummary> _all = [];
  List<String> _tags = [];
  List<String> _paths = [];
  String _query = '';
  String? _tagFilter;
  String? _pathFilter;
  bool _loading = true;
  Object? _error;

  /// Shared preview loader backed by the document service. Both the browse
  /// list and the detail panel (via the same service) reuse its LRU cache, so
  /// a document's bytes are read at most once across surfaces. Injectable via
  /// [DocumentsScreen.previewLoader] (tests swap in a synchronous thumbnailer).
  late final DocumentPreviewLoader _previewLoader =
      widget.previewLoader ??
      DocumentPreviewLoader(
        bytesSource: (id) => widget.documentService.readBytes(id),
      );

  @override
  void initState() {
    super.initState();
    widget.refreshTick?.addListener(_onRefresh);
    _load();
  }

  @override
  void dispose() {
    widget.refreshTick?.removeListener(_onRefresh);
    super.dispose();
  }

  void _onRefresh() => _load();

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        widget.documentService.listDocuments(),
        widget.documentService.listTags(),
        widget.documentService.listPaths(),
      ]);
      if (!mounted) return;
      setState(() {
        _all = results[0] as List<DocumentSummary>;
        _tags = results[1] as List<String>;
        _paths = results[2] as List<String>;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e;
        _loading = false;
      });
    }
  }

  List<DocumentSummary> get _filtered {
    final q = _query.trim().toLowerCase();
    return _all.where((d) {
      if (_tagFilter != null && !d.tags.contains(_tagFilter)) return false;
      if (_pathFilter != null && !d.paths.contains(_pathFilter)) return false;
      if (q.isNotEmpty &&
          !d.title.toLowerCase().contains(q) &&
          !d.id.toLowerCase().contains(q)) {
        return false;
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                onChanged: (v) => setState(() => _query = v),
                decoration: const InputDecoration(
                  labelText: 'Filter documents',
                  prefixIcon: Icon(Icons.filter_list),
                  border: OutlineInputBorder(),
                ),
              ),
              if (_tags.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in _tags)
                      FilterChip(
                        key: ValueKey('filter-$tag'),
                        label: Text(tag),
                        selected: _tagFilter == tag,
                        visualDensity: VisualDensity.compact,
                        labelStyle: TextStyle(
                          fontSize: 11.5,
                          color: tagColorFor(tag),
                          fontWeight: FontWeight.w600,
                        ),
                        backgroundColor: tagTintFor(context, tag),
                        side: BorderSide(
                          color: tagColorFor(tag).withValues(alpha: 0.45),
                        ),
                        onSelected: (v) =>
                            setState(() => _tagFilter = v ? tag : null),
                      ),
                  ],
                ),
              ],
              if (_paths.isNotEmpty) ...[
                const SizedBox(height: 8),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final path in _paths)
                      FilterChip(
                        label: Text(path),
                        selected: _pathFilter == path,
                        visualDensity: VisualDensity.compact,
                        labelStyle: TextStyle(
                          fontSize: 11.5,
                          // Chip themes can default labels to a light color;
                          // pin the readable onSurfaceVariant explicitly so
                          // path chips stay dark-on-light (and light-on-dark).
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        onSelected: (v) =>
                            setState(() => _pathFilter = v ? path : null),
                      ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Could not load documents',
        subtitle: '$_error',
      );
    }
    if (_all.isEmpty) {
      return EmptyState(
        icon: Icons.folder_open,
        title: 'No documents yet',
        subtitle:
            'Use "Add files" on the Search tab to ingest your first file.',
      );
    }
    final filtered = _filtered;
    if (filtered.isEmpty) {
      return const EmptyState(
        icon: Icons.filter_alt_off,
        title: 'No documents match',
        subtitle: 'Clear or change the filters above.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: GridView.builder(
        padding: const EdgeInsets.all(16),
        // Keep the pull-to-refresh gesture alive even when a filtered grid has
        // few (or no) tiles that would otherwise not fill the viewport.
        physics: const AlwaysScrollableScrollPhysics(),
        gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
          // ~3:4 portrait preview tiles; the column count adapts to width.
          maxCrossAxisExtent: 240,
          mainAxisSpacing: 12,
          crossAxisSpacing: 12,
          childAspectRatio: 3 / 4,
        ),
        itemCount: filtered.length,
        itemBuilder: (context, i) => _DocumentPreviewTile(
          document: filtered[i],
          loader: _previewLoader,
          onOpen: () => widget.onOpenDocument(filtered[i]),
        ),
      ),
    );
  }
}

/// A large, tappable preview tile for the Documents grid.
///
/// The document preview (image / PDF first page / type-colored placeholder)
/// fills the whole tile. A bottom gradient scrim keeps the title readable
/// regardless of the image; the document's tags are overlaid near the top as
/// compact dark-translucent chips (readable over arbitrary preview content).
class _DocumentPreviewTile extends StatelessWidget {
  const _DocumentPreviewTile({
    required this.document,
    required this.loader,
    required this.onOpen,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;
  final VoidCallback onOpen;

  @override
  Widget build(BuildContext context) {
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Stack(
          fit: StackFit.expand,
          children: [
            DocumentTilePreview(
              key: ValueKey('tile-${document.id}'),
              document: document,
              loader: loader,
            ),
            // Gradient scrim anchored at the base: transparent at the top,
            // progressively darker toward the bottom so the title stays
            // readable over any preview content.
            const IgnorePointer(child: _TileScrim()),
            if (document.tags.isNotEmpty)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final tag in document.tags)
                      TagChip(
                        key: ValueKey('tile-tag-$tag'),
                        label: tag,
                        overlay: true,
                      ),
                  ],
                ),
              ),
            Positioned(
              left: 10,
              right: 10,
              bottom: 8,
              child: Text(
                document.title,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  shadows: const [
                    Shadow(color: Colors.black87, blurRadius: 6),
                    Shadow(color: Colors.black54, blurRadius: 2),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The bottom scrim for [_DocumentPreviewTile].
class _TileScrim extends StatelessWidget {
  const _TileScrim();

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: const Alignment(0, -0.5),
          end: Alignment.bottomCenter,
          stops: const [0.0, 0.55, 1.0],
          colors: [
            Colors.transparent,
            Colors.black.withValues(alpha: 0.45),
            Colors.black.withValues(alpha: 0.85),
          ],
        ),
      ),
    );
  }
}
