import 'package:flutter/material.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart' show DocumentService;
import '../features/search_service.dart'
    show SearchHitDto, SearchMode, SearchService;
import 'document_preview_view.dart' show DocumentPlaceholder, DocumentThumbnail;
import 'document_view.dart' show DocumentSummary;
import 'widgets.dart' show EmptyState, HighlightedSnippet, TagChip;

/// What a search result should do when tapped.
typedef DocumentOpener = void Function(DocumentSummary summary);

/// Search page: query bar, tag/path filters, mode toggle, highlighted results.
class SearchScreen extends StatefulWidget {
  const SearchScreen({
    super.key,
    required this.searchService,
    required this.onOpenDocument,
    required this.tags,
    this.paths = const [],
    this.documentService,
    this.previewLoader,
    this.onConfigureAi,
  });

  final SearchService searchService;
  final DocumentOpener onOpenDocument;

  /// Resolves document metadata for search-result thumbnails. Search hits only
  /// carry `documentId`/tags/paths, so a thumbnail that wants to show an image
  /// or PDF preview needs this to fetch the MIME type. Optional so tests can
  /// omit it (the thumbnail then degrades to the type-colored tile).
  final DocumentService? documentService;

  /// The preview loader for search-result thumbnails. Defaults to a loader
  /// bound to [documentService]; injectable so widget tests can swap in a
  /// synchronous (isolate-free) thumbnailer.
  final DocumentPreviewLoader? previewLoader;

  /// Available tag names for the filter dropdown / chips.
  final List<String> tags;

  /// Available hierarchy paths for the path filter dropdown.
  final List<String> paths;

  final VoidCallback? onConfigureAi;

  @override
  State<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends State<SearchScreen> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  SearchMode _mode = SearchMode.hybrid;
  final List<String> _selectedTags = [];
  String? _selectedPath;
  List<SearchHitDto> _results = [];
  bool _loading = false;
  Object? _error;

  /// Resolved document summaries keyed by document id. Populated after search
  /// so each result can display its real title instead of a raw path.
  final Map<String, DocumentSummary> _docSummaries = {};

  /// Shared preview loader backed by the optional document service. Injectable
  /// via [SearchScreen.previewLoader] (tests swap in a synchronous thumbnailer);
  /// when no service is provided search-result thumbnails degrade to the
  /// type-colored placeholder tile.
  DocumentPreviewLoader? _previewLoader;

  @override
  void initState() {
    super.initState();
    final service = widget.documentService;
    final injected = widget.previewLoader;
    if (injected != null) {
      _previewLoader = injected;
    } else if (service != null) {
      _previewLoader = DocumentPreviewLoader(
        bytesSource: (id) => service.readBytes(id),
      );
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _runSearch() async {
    final query = _controller.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
      });
      return;
    }
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final hits = widget.searchService.query(
        query,
        mode: _mode,
        tags: _selectedTags,
        paths: _selectedPath == null ? const [] : [_selectedPath!],
        limit: 60,
      );
      if (!mounted) return;
      setState(() => _results = hits);
      _resolveTitles(hits);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = e);
      _results = [];
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toggleTag(String tag, bool selected) {
    setState(() {
      if (selected) {
        if (!_selectedTags.contains(tag)) _selectedTags.add(tag);
      } else {
        _selectedTags.remove(tag);
      }
    });
    _runSearch();
  }

  DocumentSummary _summaryOf(SearchHitDto hit) {
    final cached = _docSummaries[hit.documentId];
    return DocumentSummary(
      id: hit.documentId,
      title: cached?.title ?? _titleFrom(hit),
      snippet: hit.snippet,
      tags: hit.tags,
      paths: hit.paths,
    );
  }

  String _titleFrom(SearchHitDto hit) {
    // Prefer a resolved document title from the repository.
    final cached = _docSummaries[hit.documentId];
    if (cached != null) return cached.title;
    // Fall back to a path segment as a human-readable title hint.
    if (hit.paths.isNotEmpty) return hit.paths.first;
    // Never surface the raw internal document id: fall back to a friendly
    // placeholder when the search index has no path/title metadata.
    return 'Untitled document';
  }

  /// Best-effort fetch of document metadata for each search result so the UI
  /// can display real titles instead of raw file paths.
  Future<void> _resolveTitles(List<SearchHitDto> hits) async {
    final service = widget.documentService;
    if (service == null) return;
    for (final hit in hits) {
      if (_docSummaries.containsKey(hit.documentId)) continue;
      try {
        final summary = await service.getDocument(hit.documentId);
        if (!mounted) return;
        setState(() => _docSummaries[hit.documentId] = summary);
      } catch (_) {
        // Metadata fetch failed — fallback to path-based title.
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                controller: _controller,
                focusNode: _focusNode,
                textInputAction: TextInputAction.search,
                onSubmitted: (_) => _runSearch(),
                decoration: InputDecoration(
                  labelText: 'Search your documents',
                  prefixIcon: const Icon(Icons.search),
                  suffixIcon: IconButton(
                    tooltip: 'Search',
                    onPressed: _runSearch,
                    icon: const Icon(Icons.arrow_forward),
                  ),
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 12),
              SegmentedButton<SearchMode>(
                segments: const [
                  ButtonSegment(
                    value: SearchMode.exact,
                    icon: Icon(Icons.text_fields),
                    label: Text('Exact'),
                  ),
                  ButtonSegment(
                    value: SearchMode.semantic,
                    icon: Icon(Icons.graphic_eq),
                    label: Text('Semantic'),
                  ),
                  ButtonSegment(
                    value: SearchMode.hybrid,
                    icon: Icon(Icons.tune),
                    label: Text('Hybrid'),
                  ),
                ],
                selected: {_mode},
                onSelectionChanged: (sel) {
                  setState(() => _mode = sel.first);
                  _runSearch();
                },
                showSelectedIcon: false,
              ),
              const SizedBox(height: 8),
              if (widget.tags.isNotEmpty) ...[
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final tag in widget.tags)
                      TagChip(
                        key: ValueKey('search-filter-$tag'),
                        label: tag,
                        selected: _selectedTags.contains(tag),
                        onSelected: (v) => _toggleTag(tag, v),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
              ],
              if (widget.paths.isNotEmpty)
                DropdownButtonFormField<String>(
                  initialValue: _selectedPath,
                  decoration: const InputDecoration(
                    labelText: 'Filter by path',
                    prefixIcon: Icon(Icons.folder_open),
                    border: OutlineInputBorder(),
                  ),
                  items: [
                    const DropdownMenuItem(
                      value: null,
                      child: Text('All paths'),
                    ),
                    ...widget.paths.map(
                      (p) => DropdownMenuItem(value: p, child: Text(p)),
                    ),
                  ],
                  onChanged: (v) {
                    _selectedPath = v;
                    _runSearch();
                  },
                ),
            ],
          ),
        ),
        Expanded(child: _buildResults()),
      ],
    );
  }

  Widget _buildResults() {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return EmptyState(
        icon: Icons.error_outline,
        title: 'Search failed',
        subtitle: '$_error',
      );
    }
    if (_controller.text.trim().isEmpty) {
      return EmptyState(
        icon: Icons.manage_search,
        title: 'Type a query to search',
        subtitle:
            'Search full-text or semantically, filter by tag and path, and '
            'click a result to open the document.',
      );
    }
    if (_results.isEmpty) {
      return EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        subtitle: 'Try different keywords or switch search mode.',
      );
    }
    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: _results.length,
      separatorBuilder: (_, _) => const SizedBox(height: 8),
      itemBuilder: (context, i) {
        final hit = _results[i];
        return Card(
          child: InkWell(
            onTap: () => widget.onOpenDocument(_summaryOf(hit)),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _SearchResultThumb(
                    hit: hit,
                    documentService: widget.documentService,
                    loader: _previewLoader,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Expanded(
                              child: Text(
                                _titleFrom(hit),
                                style: Theme.of(context).textTheme.titleMedium,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            Text(
                              '${((hit.score * 100).round()).clamp(0, 100)}%',
                              style: Theme.of(context).textTheme.labelSmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        HighlightedSnippet(
                          text: hit.snippet,
                          highlights: hit.highlights,
                          maxLines: 3,
                        ),
                        if (hit.tags.isNotEmpty || hit.paths.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          Wrap(
                            spacing: 6,
                            runSpacing: 6,
                            children: [
                              for (final tag in hit.tags)
                                TagChip(
                                  key: ValueKey('hit-tag-$tag'),
                                  label: tag,
                                ),
                              for (final path in hit.paths)
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
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// A thumbnail for a search result.
///
/// Search hits don't carry the MIME type, so when a [DocumentService] is
/// available the widget resolves it once (cheap metadata read, cached in the
/// loader's LRU) and renders a real image/PDF preview; otherwise it degrades
/// to the deterministic type-colored placeholder tile.
class _SearchResultThumb extends StatefulWidget {
  const _SearchResultThumb({
    required this.hit,
    required this.documentService,
    required this.loader,
  });

  final SearchHitDto hit;
  final DocumentService? documentService;
  final DocumentPreviewLoader? loader;

  @override
  State<_SearchResultThumb> createState() => _SearchResultThumbState();
}

class _SearchResultThumbState extends State<_SearchResultThumb> {
  DocumentSummary? _summary;

  /// Best-effort title for a search hit (mirrors `_titleFrom` on the parent
  /// state); never surfaces a raw internal document id.
  static String _titleFor(SearchHitDto hit) =>
      hit.paths.isNotEmpty ? hit.paths.first : 'Untitled document';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(_SearchResultThumb oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.hit.documentId != widget.hit.documentId) {
      _summary = null;
      _resolve();
    }
  }

  Future<void> _resolve() async {
    final service = widget.documentService;
    if (service == null) return;
    try {
      final doc = await service.getDocument(widget.hit.documentId);
      if (!mounted) return;
      setState(() => _summary = doc);
    } catch (_) {
      // Metadata fetch failed → keep the placeholder tile.
    }
  }

  @override
  Widget build(BuildContext context) {
    final loader = widget.loader;
    final summary = _summary;
    if (loader != null && summary != null) {
      return DocumentThumbnail(
        key: ValueKey('search-thumb-${widget.hit.documentId}'),
        document: summary,
        loader: loader,
        size: 48,
      );
    }
    // No service, still resolving, or metadata failed → colored placeholder.
    final fallback =
        summary ??
        DocumentSummary(
          id: widget.hit.documentId,
          title: _titleFor(widget.hit),
          tags: widget.hit.tags,
          paths: widget.hit.paths,
        );
    return SizedBox(
      width: 48,
      height: 48,
      child: DocumentPlaceholder(document: fallback),
    );
  }
}
