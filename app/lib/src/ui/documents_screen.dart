import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart' show DocumentService;
import 'document_preview_view.dart' show DocumentThumbnail;
import 'document_view.dart' show DocumentSummary;
import 'search_screen.dart' show DocumentOpener;
import 'widgets.dart' show EmptyState, tagColorFor, tagTintFor;

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
                        backgroundColor: tagTintFor(tag),
                        side: BorderSide(
                          color: tagColorFor(tag).withValues(alpha: 0.45),
                        ),
                        avatar: const SizedBox.shrink(),
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
                        labelStyle: const TextStyle(fontSize: 11.5),
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
      child: ListView.separated(
        padding: const EdgeInsets.all(16),
        itemCount: filtered.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (context, i) => _DocumentCard(
          document: filtered[i],
          loader: _previewLoader,
          onTap: () => widget.onOpenDocument(filtered[i]),
        ),
      ),
    );
  }
}

class _DocumentCard extends StatelessWidget {
  const _DocumentCard({
    required this.document,
    required this.loader,
    required this.onTap,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              DocumentThumbnail(
                key: ValueKey('thumb-${document.id}'),
                document: document,
                loader: loader,
                size: 56,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      document.title,
                      style: Theme.of(context).textTheme.titleMedium,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    if (document.tags.isNotEmpty || document.paths.isNotEmpty)
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: [
                          for (final tag in document.tags)
                            Chip(
                              key: ValueKey('card-tag-$tag'),
                              label: Text(tag),
                              visualDensity: VisualDensity.compact,
                              labelStyle: TextStyle(
                                fontSize: 11.5,
                                color: tagColorFor(tag),
                                fontWeight: FontWeight.w600,
                              ),
                              backgroundColor: tagTintFor(tag),
                              side: BorderSide(
                                color: tagColorFor(tag).withValues(alpha: 0.45),
                              ),
                              avatar: const SizedBox.shrink(),
                            ),
                          for (final path in document.paths)
                            Chip(
                              avatar: const Icon(
                                Icons.folder_outlined,
                                size: 14,
                              ),
                              label: Text(path),
                              visualDensity: VisualDensity.compact,
                              labelStyle: const TextStyle(fontSize: 11.5),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
