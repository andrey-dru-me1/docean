import 'package:flutter/material.dart';

import '../features/search_service.dart'
    show SearchHitDto, SearchMode, SearchService;
import 'document_view.dart' show DocumentSummary;
import 'widgets.dart';

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
    this.onConfigureAi,
  });

  final SearchService searchService;
  final DocumentOpener onOpenDocument;

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

  DocumentSummary _summaryOf(SearchHitDto hit) => DocumentSummary(
    id: hit.documentId,
    title: _titleFrom(hit),
    snippet: hit.snippet,
    tags: hit.tags,
    paths: hit.paths,
  );

  String _titleFrom(SearchHitDto hit) =>
      // Prefer a path segment as a human-readable title hint.
      hit.paths.isNotEmpty ? hit.paths.first : hit.documentId;
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
                      FilterChip(
                        label: Text(tag),
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
        const Divider(height: 1),
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
                        '${(hit.score * 100).round()}%',
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
                          Chip(
                            avatar: const Icon(Icons.label_outline, size: 14),
                            label: Text(tag),
                            visualDensity: VisualDensity.compact,
                          ),
                        for (final path in hit.paths)
                          Chip(
                            avatar: const Icon(Icons.folder_outlined, size: 14),
                            label: Text(path),
                            visualDensity: VisualDensity.compact,
                          ),
                      ],
                    ),
                  ],
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
