import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart'
    show BulkOrganizer, DocumentService, NoopBulkOrganizer;
import '../features/tag_hierarchy.dart' show maximalTags, suggestTagCompletions;
import 'document_preview_view.dart' show DocumentTilePreview;
import 'document_view.dart' show DocumentSummary;
import 'hierarchy_view.dart'
    show HierarchyView, docProperties, docScopes;
import 'search_screen.dart' show DocumentOpener;
import 'tag_hierarchy_view.dart' show TagHierarchyView;
import 'widgets.dart' show EmptyState, TagChip, wrapDocumentDragOut;

  /// Categories for filtering documents by file type.
enum FileTypeCategory {
  all('All files'),
  pdf('PDF'),
  textMarkdown('Text/Markdown'),
  images('Images'),
  documents('Documents (DOCX, ODT)'),
  email('Email (EML)');

  const FileTypeCategory(this.label);

  final String label;

  /// Returns `true` if [mimeType] matches this category. For [all], returns
  /// `null` so the filter check is skipped.
  bool? matchesMime(String? mimeType) {
    if (this == all) return null;
    if (mimeType == null) return false;
    return switch (this) {
      pdf => mimeType == 'application/pdf',
      textMarkdown => mimeType.startsWith('text/'),
      images => mimeType.startsWith('image/'),
      documents =>
        mimeType ==
            'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
            mimeType == 'application/vnd.oasis.opendocument.text',
      email => mimeType == 'message/rfc822',
      _ => false,
    };
  }
}

enum DocumentsViewMode { grid, hierarchy, tags }

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
    this.bulkOrganizer = const NoopBulkOrganizer(),
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

  /// The bulk "Re-organize all documents" pipeline. Historically hosted on the
  /// Settings screen; this surface now owns the bulk actions, so the same
  /// corpus-wide pass lives in the selection toolbar. Defaults to a no-op so
  /// tests (and embedding shells) work without the native library.
  final BulkOrganizer bulkOrganizer;

  @override
  State<DocumentsScreen> createState() => _DocumentsScreenState();
}

class _DocumentsScreenState extends State<DocumentsScreen> {
  List<DocumentSummary> _all = [];
  List<String> _tags = [];
  List<String> _paths = [];
  String _query = '';
  final Set<String> _tagFilters = {};
  String? _pathFilter;
  FileTypeCategory? _fileTypeFilter;
  bool _loading = true;
  Object? _error;

  /// Whether the grid is in selection mode. While active, tapping a tile
  /// toggles selection instead of opening the document, and a bulk-action bar
  /// replaces the browsing chrome.
  bool _selectionMode = false;

  /// The ids selected by the user (in selection mode).
  final Set<String> _selected = <String>{};

  /// Whether a bulk operation (tag edit / delete / re-organize) is running.
  bool _busy = false;

  /// Current view mode (grid or hierarchy).
  DocumentsViewMode _viewMode = DocumentsViewMode.grid;

  /// The selected scope for the hierarchy view (null = "(no scope)").
  String? _hierScope;

  /// The property key ordering for the hierarchy view.
  List<String> _hierOrder = [];

  /// Whether the user has manually reordered the hierarchy grouping keys.
  /// When true, scope changes still recompute, but filter changes preserve
  /// the user's custom order.
  bool _hierOrderCustomized = false;

  /// Progress notifier for the async "Suggest title"/"Suggest tags" passes so
  /// the corner progress chip can show completed/total counts.
  final CountNotifier _suggestProgress = CountNotifier();

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
    // Only show the loading spinner on the very first load (empty list).
    // Subsequent refreshes (ingestion, meta-info changes) silently replace
    // the grid contents so the visible tiles never flash to a spinner.
    final isFirstLoad = _all.isEmpty;
    setState(() {
      if (isFirstLoad) _loading = true;
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
        // Only show tags that appear on at least one document.
        final usedTags = <String>{
          for (final doc in _all) ...doc.tags,
        };
        _tags = (results[1] as List<String>)
            .where(usedTags.contains)
            .toList();
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
      // Intersection semantics: with multiple tags selected, a document must
      // carry EVERY selected tag (an empty selection matches everything). A
      // selected tag matches the document when any of its tags equals it OR
      // starts a subtree under it (`T/...`), so selecting a dirtag chip
      // filters by the whole subtree.
      if (_tagFilters.isNotEmpty &&
          !_tagFilters.every(
            (f) => d.tags.any((t) => t == f || t.startsWith('$f/')),
          )) {
        return false;
      }
      if (_pathFilter != null && !d.paths.contains(_pathFilter)) {
        return false;
      }
      if (_fileTypeFilter != null &&
          _fileTypeFilter!.matchesMime(d.mimeType) == false) {
        return false;
      }
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
        if (_selectionMode) _buildSelectionBar() else _buildFilterBar(context),
        const Divider(height: 1),
        Expanded(child: _buildBody()),
        if (_suggestProgress.active) _buildSuggestProgressChip(context),
      ],
    );
  }

  /// The browsing chrome: filter field, tag/path filter chips, and a "Select all"
  /// icon button that enters selection mode with all filtered documents selected.
  Widget _buildFilterBar(BuildContext context) {
    final filtered = _filtered;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              // Flexible so the filter bar never overflows when the window is
              // narrow (e.g. sidebar open): the field shrinks first and keeps
              // its 260px preferred width when there is room.
              Flexible(
                child: SizedBox(
                  width: 260,
                  child: TextField(
                    onChanged: (v) => setState(() => _query = v),
                    decoration: const InputDecoration(
                      labelText: 'Filter documents',
                      prefixIcon: Icon(Icons.filter_list),
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              PopupMenuButton<FileTypeCategory>(
                key: const ValueKey('file-type-filter'),
                tooltip: 'Filter by file type',
                onSelected: (cat) => setState(() => _fileTypeFilter = cat),
                itemBuilder: (context) => [
                  for (final cat in FileTypeCategory.values)
                    PopupMenuItem<FileTypeCategory>(
                      value: cat,
                      child: Row(
                        children: [
                          if (_fileTypeFilter == cat)
                            Icon(Icons.check, size: 16, color: Theme.of(context).colorScheme.primary)
                          else
                            const SizedBox(width: 16),
                          const SizedBox(width: 8),
                          Flexible(child: Text(cat.label)),
                        ],
                      ),
                    ),
                ],
                child: InputChip(
                  label: Text(_fileTypeFilter?.label ?? 'All files'),
                  avatar: Icon(
                    Icons.extension_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                  visualDensity: VisualDensity.compact,
                  selected: _fileTypeFilter != null &&
                      _fileTypeFilter != FileTypeCategory.all,
                  labelStyle: TextStyle(
                    fontSize: 11.5,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              SegmentedButton<DocumentsViewMode>(
                key: const ValueKey('view-mode-toggle'),
                showSelectedIcon: false,
                style: const ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  padding: WidgetStatePropertyAll(
                    EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                segments: const [
                  ButtonSegment<DocumentsViewMode>(
                    value: DocumentsViewMode.grid,
                    icon: Icon(Icons.grid_view, semanticLabel: 'Grid'),
                  ),
                  ButtonSegment<DocumentsViewMode>(
                    value: DocumentsViewMode.hierarchy,
                    icon: Icon(Icons.account_tree, semanticLabel: 'Hierarchy'),
                  ),
                  ButtonSegment<DocumentsViewMode>(
                    value: DocumentsViewMode.tags,
                    icon: Icon(Icons.sell, semanticLabel: 'Tags'),
                  ),
                ],
                selected: {_viewMode},
                onSelectionChanged: (mode) =>
                    setState(() => _viewMode = mode.first),
              ),
              const SizedBox(width: 8),
              IconButton(
                key: const ValueKey('select-documents'),
                tooltip: 'Select all',
                onPressed: filtered.isEmpty
                    ? null
                    : () {
                        _selectAllFiltered();
                        _enterSelectionMode();
                      },
                icon: const Icon(Icons.select_all, size: 20),
              ),
            ],
          ),
          if (_tags.isNotEmpty) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in _tags)
                  TagChip(
                    key: ValueKey('filter-$tag'),
                    label: tag,
                    selected: _tagFilters.contains(tag),
                    onSelected: (v) => setState(() {
                      if (v) {
                        _tagFilters.add(tag);
                      } else {
                        _tagFilters.remove(tag);
                      }
                    }),
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
            'Drag files anywhere on this page, or tap the upload icon at the '
            'top, to add your first library document.',
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
    if (_viewMode == DocumentsViewMode.tags) {
      return TagHierarchyView(
        key: const ValueKey('tag-hierarchy-view'),
        documents: filtered,
        onOpenDocument: widget.onOpenDocument,
      );
    }
    if (_viewMode == DocumentsViewMode.hierarchy) {
      _ensureHierOrder();
      return HierarchyView(
        key: const ValueKey('hierarchy-view'),
        documents: filtered,
        scope: _hierScope,
        order: _hierOrder,
        onOpenDocument: widget.onOpenDocument,
        onPickScope: (scope) => setState(() {
          _hierScope = scope;
          _hierOrder = _orderKeysForScope();
          _hierOrderCustomized = false;
        }),
        onPickOrder: _showOrderSheet,
        selectionMode: _selectionMode,
        selectedIds: _selected,
        onToggleSelected: _selectionMode ? _toggleSelected : null,
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
        itemBuilder: (context, i) {
          final document = filtered[i];
          final tile = _DocumentPreviewTile(
            document: document,
            loader: _previewLoader,
            selectionMode: _selectionMode,
            selected: _selected.contains(document.id),
            onTapTile: _selectionMode
                ? () => _toggleSelected(document.id)
                : () => widget.onOpenDocument(document),
            onCheckboxTap: _selectionMode
                ? () => _toggleSelected(document.id)
                : () => _enterSelectionMode(document.id),
            onLongPress: () => _enterSelectionMode(document.id),
            onTagTap: _toggleTagFilter,
          );
          return wrapDocumentDragOut(
            documentId: document.id,
            fileName: _dragFileName(document),
            mimeType: document.mimeType,
            readBytes: () => widget.documentService.readBytes(document.id),
            child: tile,
          );
        },
      ),
    );
  }

  // --- Selection mode ------------------------------------------------------

  /// Enter selection mode, optionally pre-selecting [initialId] (used by
  /// long-press: the long-pressed tile becomes the first selection).
  void _enterSelectionMode([String? initialId]) {
    setState(() {
      _selectionMode = true;
      if (initialId != null) _selected.add(initialId);
    });
  }

  /// Leave selection mode (done/close affordance, or a completed bulk op).
  void _exitSelectionMode() {
    setState(() {
      _selectionMode = false;
      _selected.clear();
    });
  }

  void _toggleSelected(String id) {
    setState(() {
      if (!_selected.add(id)) _selected.remove(id);
    });
  }

  /// Toggle a tag in the filter bar: clicking a tag that is already an active
  /// filter removes it; clicking a tag that is not active adds it.
  void _toggleTagFilter(String tag) {
    setState(() {
      if (!_tagFilters.add(tag)) _tagFilters.remove(tag);
    });
  }

  /// Select every document matching the *current* filters (tag/path/title
  /// query). Documents hidden by the active filters are never touched.
  void _selectAllFiltered() {
    setState(() {
      _selected
        ..clear()
        ..addAll(_filtered.map((d) => d.id));
    });
  }

  /// Toggle the current filtered selection: when every filtered document is
  /// already selected, deselect them all ("Clear"); otherwise select them all.
  void _toggleSelectAll() {
    setState(() {
      if (_allFilteredSelected) {
        _selected.removeWhere(_filtered.map((d) => d.id).toSet().contains);
      } else {
        _selected.addAll(_filtered.map((d) => d.id));
      }
    });
  }

  /// Whether _every_ currently-filtered document is selected.
  bool get _allFilteredSelected {
    final filtered = _filtered;
    return filtered.isNotEmpty &&
        filtered.every((d) => _selected.contains(d.id));
  }

  // --- Hierarchy view ------------------------------------------------------

  /// The documents belonging to the selected scope: every document carrying
  /// that `scope:` tag (selecting an ancestor scope therefore includes its
  /// descendant documents), or unscoped documents for [scope] = null.
  List<DocumentSummary> get _hierScopedDocs {
    if (_hierScope == null) {
      return _filtered.where((d) => docScopes(d.tags).isEmpty).toList();
    }
    return _filtered
        .where((d) => docScopes(d.tags).contains(_hierScope))
        .toList();
  }

  /// The property keys available on the selected scope's documents, sorted
  /// alphabetically (the default grouping order).
  List<String> _orderKeysForScope() {
    final keys = <String>{
      for (final doc in _hierScopedDocs)
        for (final prop in docProperties(doc.tags)) prop.key,
    }.toList()
      ..sort();
    return keys;
  }

  /// Recomputes [_hierOrder] to the scope's current key union unless the user
  /// has customized the order (their ordering is preserved).
  void _ensureHierOrder() {
    if (_hierOrderCustomized) return;
    final next = _orderKeysForScope();
    if (!listEquals(_hierOrder, next)) {
      _hierOrder = next;
    }
  }

  /// The grouping-order editor: a bottom sheet with a reorderable list of the
  /// property keys present on the selected scope's documents.  Confirming
  /// applies the new order and marks it as user-customized.
  Future<void> _showOrderSheet() async {
    final keys = _orderKeysForScope();
    if (keys.isEmpty) {
      _showSnack(context, 'No grouping properties on these documents.');
      return;
    }
    final result = await showModalBottomSheet<List<String>>(
      context: context,
      builder: (sheetContext) =>
          _HierarchyOrderSheet(initialOrder: List.of(_hierOrder)),
    );
    if (result == null || !mounted) return;
    setState(() {
      _hierOrder = result;
      _hierOrderCustomized = true;
    });
  }

  /// The toolbar shown during selection mode: selected count, select-all,
  /// bulk tag/suggest/delete actions, and the "Re-organize selected" bulk pass
  /// that formerly lived on the Settings screen.
  Widget _buildSelectionBar() {
    final count = _selected.length;
    return Material(
      key: const ValueKey('selection-bar'),
      color: Theme.of(context).colorScheme.surfaceContainerHigh,
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
          child: Row(
            children: [
              IconButton(
                key: const ValueKey('exit-selection'),
                tooltip: 'Close selection',
                onPressed: _busy ? null : _exitSelectionMode,
                icon: const Icon(Icons.close),
              ),
              const SizedBox(width: 4),
              Text(
                '$count selected',
                key: const ValueKey('selection-count'),
                style: Theme.of(context).textTheme.titleSmall,
              ),
              const Spacer(),
              TextButton.icon(
                key: const ValueKey('select-all'),
                onPressed: _busy ? null : _toggleSelectAll,
                icon: Icon(
                  _allFilteredSelected ? Icons.deselect : Icons.select_all,
                  size: 18,
                ),
                label: Text(_allFilteredSelected ? 'Clear' : 'Select all'),
              ),
              const SizedBox(width: 8),
              if (_busy)
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 12),
                  child: SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              else ...[
                _BulkToolbarAction(
                  key: const ValueKey('bulk-add-tag'),
                  tooltip: 'Add tag…',
                  icon: Icons.add,
                  onPressed: count == 0 ? null : _bulkAddTag,
                ),
                _BulkToolbarAction(
                  key: const ValueKey('bulk-remove-tag'),
                  tooltip: 'Remove tag…',
                  icon: Icons.remove,
                  onPressed: count == 0 ? null : _bulkRemoveTag,
                ),
                _BulkToolbarAction(
                  key: const ValueKey('bulk-suggest-title'),
                  tooltip: 'Suggest title',
                  icon: Icons.auto_fix_high,
                  onPressed: count == 0
                      ? null
                      : () => _runBulkSuggest(titles: true),
                ),
                _BulkToolbarAction(
                  key: const ValueKey('bulk-suggest-tags'),
                  tooltip: 'Suggest tags',
                  icon: Icons.sell_outlined,
                  onPressed: count == 0
                      ? null
                      : () => _runBulkSuggest(titles: false),
                ),
                _BulkToolbarAction(
                  key: const ValueKey('bulk-reorganize'),
                  tooltip: 'Re-organize selected',
                  icon: Icons.auto_awesome,
                  onPressed: count == 0 ? null : _reorganizeSelected,
                ),
                _BulkToolbarAction(
                  key: const ValueKey('bulk-delete'),
                  tooltip: 'Delete',
                  icon: Icons.delete_outline,
                  destructive: true,
                  onPressed: count == 0 ? null : _confirmBulkDelete,
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  /// Re-organize **only** the selected documents.  The async
  /// [BulkOrganizer.reorganizeSelected] bridge runs on Rust's worker pool
  /// (via `#[frb]` async), so the Flutter UI isolate stays responsive while the
  /// deterministic organizer runs over the corpus.
  Future<void> _reorganizeSelected() async {
    final ids = Set<String>.of(_selected);
    if (ids.isEmpty || _busy) return;
    setState(() => _busy = true);
    try {
      final result = await widget.bulkOrganizer.reorganizeSelected(ids);
      if (!mounted) return;
      _showSnack(
        context,
        'Re-organized: ${result.updated} updated, ${result.skipped} skipped.',
      );
      _exitSelectionMode();
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnack(context, 'Could not re-organize: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Prompts for a single tag name and appends it to every selected document
  /// (batch [`DocumentService.bulkTags`] with only `add` — existing tags are
  /// honored, so this appends rather than replaces). Existing repository tags
  /// are offered as tappable suggestions, but a brand-new tag can also be typed.
  Future<void> _bulkAddTag() async {
    final tag = await _promptForTag(
      context,
      title: 'Add tag',
      tags: _tags,
    );
    if (tag == null || !mounted) return;
    final ids = List.of(_selected);
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.documentService.bulkTags(ids, add: [tag]);
      if (!mounted) return;
      _showSnack(
        context,
        'Added "$tag" to ${ids.length} document${ids.length == 1 ? '' : 's'}.',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnack(context, 'Could not add tag: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Prompts for a tag name to strip from every selected document. Unlike the
  /// add flow (free text), the removal dialog forces a choice from the tags
  /// that actually exist on the selected documents.
  Future<void> _bulkRemoveTag() async {
    final ids = List.of(_selected);
    if (ids.isEmpty || _busy) return;
    // The candidate list is the union of tags across every selected document —
    // removing a tag nobody has is a no-op, so only real tags are offered.
    final existing = <String>{
      for (final doc in _all)
        if (ids.contains(doc.id)) ...doc.tags,
    }.toList()..sort();
    final tag = await _promptForExistingTag(context, tags: existing);
    if (tag == null || !mounted) return;
    if (ids.isEmpty) return;
    setState(() => _busy = true);
    try {
      await widget.documentService.bulkTags(ids, remove: [tag]);
      if (!mounted) return;
      _showSnack(
        context,
        'Removed "$tag" from ${ids.length} document${ids.length == 1 ? '' : 's'}.',
      );
      await _load();
    } catch (e) {
      if (!mounted) return;
      _showSnack(context, 'Could not remove tag: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Delete confirmation dialog for the current selection.
  Future<void> _confirmBulkDelete() async {
    final count = _selected.length;
    if (count == 0 || _busy) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete $count document${count == 1 ? '' : 's'}?'),
        content: const Text('This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            key: const ValueKey('confirm-bulk-delete'),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final ids = List.of(_selected);
    setState(() => _busy = true);
    try {
      await widget.documentService.bulkDelete(ids);
      if (!mounted) return;
      _showSnack(context, 'Deleted $count document${count == 1 ? '' : 's'}.');
      _exitSelectionMode();
      await _load();
      if (widget.refreshTick case final vn as ValueNotifier<int>) vn.value++;
    } catch (e) {
      if (!mounted) return;
      _showSnack(context, 'Could not delete documents: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// Run the split auto-suggest action across every selected document in the
  /// background ([suggestTitle] or [suggestTags] — the service honors the
  /// `title_manual`/`tags_manual` flags internally). Progress is surfaced via
  /// [_suggestProgress] and the corner progress chip, and per-document
  /// failures are counted and reported instead of being silently swallowed.
  Future<void> _runBulkSuggest({required bool titles}) async {
    final ids = List.of(_selected);
    if (ids.isEmpty || _suggestProgress.active) return;
    var done = 0;
    var failed = 0;
    // Publishing the pass metadata inside setState makes the corner notifier
    // visible immediately (a plain ValueNotifier write wouldn't rebuild the
    // surrounding Column's `build`, which gates the chip on `active`).
    setState(() {
      _suggestProgress
        ..total = ids.length
        ..completed = 0
        ..label = titles ? 'Suggesting titles…' : 'Suggesting tags…';
    });
    for (final id in ids) {
      try {
        if (titles) {
          await widget.documentService.suggestTitle(id);
        } else {
          await widget.documentService.suggestTags(id);
        }
      } catch (_) {
        // A single failure doesn't abort the remainder of the batch.
        failed++;
      }
      if (!mounted) return;
      done++;
      setState(() => _suggestProgress.completed = done);
    }
    if (!mounted) return;
    final succeeded = done - failed;
    if (failed > 0) {
      _showSnack(
        context,
        titles
            ? 'Titles suggested for $succeeded of $done document'
                  '${succeeded == 1 ? '' : 's'}; $failed failed.'
            : 'Tags suggested for $succeeded of $done document'
                  '${succeeded == 1 ? '' : 's'}; $failed failed.',
      );
    } else {
      _showSnack(
        context,
        titles
            ? 'Titles suggested for $done document${done == 1 ? '' : 's'}.'
            : 'Tags suggested for $done document${done == 1 ? '' : 's'}.',
      );
    }
    await _load();
  }

  Widget _buildSuggestProgressChip(BuildContext context) {
    return ValueListenableBuilder<CountProgress>(
      valueListenable: _suggestProgress,
      builder: (context, progress, _) {
        if (progress.total == 0 || progress.completed >= progress.total) {
          return const SizedBox.shrink();
        }
        final scheme = Theme.of(context).colorScheme;
        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              Card(
                color: scheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.auto_fix_high,
                        size: 16,
                        color: scheme.onSecondaryContainer,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          '${progress.label} ${progress.completed}/${progress.total}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSecondaryContainer,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  void _showSnack(BuildContext context, String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }
}

/// Prompts for a single tag name and returns the trimmed name (or `null` when
/// the user cancels). When [tags] is provided, existing tags are shown as
/// tappable suggestions below the text field.
Future<String?> _promptForTag(
  BuildContext context, {
  required String title,
  List<String>? tags,
}) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => _TagNameDialog(title: title, tags: tags),
    );

/// Prompts for one tag among [tags] (the tags that exist on the selection) and
/// returns the chosen name, or `null` when the user cancels. The dialog offers
/// a searchable list and only existing tags can be picked — no free text.
Future<String?> _promptForExistingTag(
  BuildContext context, {
  required List<String> tags,
}) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => _ExistingTagDialog(tags: tags),
    );

/// The file name the dropped document should receive.
///
/// Prefers the original ingested file name (so extensions are preserved);
/// falls back to the cleaned title with the MIME-derived extension when the
/// original name is unknown.
String _dragFileName(DocumentSummary document) {
  final original = document.originalName?.trim();
  if (original != null && original.isNotEmpty) return original;
  final title = document.title.trim();
  if (title.isEmpty) return 'document';
  return title;
}

/// A small stateful dialog that owns its [TextEditingController] for the
/// lifetime of the dialog (created in [initState], disposed in [dispose]) to
/// avoid "used after disposed" crashes during the exit animation.
class _TagNameDialog extends StatefulWidget {
  const _TagNameDialog({required this.title, this.tags});

  final String title;

  /// When provided, shows existing tags as tappable suggestions below the
  /// text field. Users can tap to apply or type a new tag name.
  final List<String>? tags;

  @override
  State<_TagNameDialog> createState() => _TagNameDialogState();
}

class _TagNameDialogState extends State<_TagNameDialog> {
  late final TextEditingController _controller = TextEditingController();

  /// Fuzzy completions for the current query (empty when the field is blank).
  List<String> _liveSuggestions = const [];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onChanged(String value) {
    final q = value.trim();
    setState(() {
      _liveSuggestions = q.isEmpty
          ? const []
          : suggestTagCompletions(q, widget.tags ?? const []);
    });
  }

  void _submit(String raw) {
    final tag = raw.trim();
    if (tag.isEmpty) return;
    Navigator.of(context).pop(tag);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  key: const ValueKey('tag-name-field'),
                  controller: _controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Tag name',
                    prefixIcon: Icon(Icons.tag, size: 18),
                    border: OutlineInputBorder(),
                  ),
                  onChanged: _onChanged,
                  onSubmitted: _submit,
                ),
              ),
            ],
          ),
          if (_liveSuggestions.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Suggestions',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              key: const ValueKey('tag-suggestions-bulk'),
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in _liveSuggestions)
                  TagChip(
                    key: ValueKey('tag-suggestion-$tag'),
                    label: tag,
                    onPressed: () {
                      _controller.text = tag;
                      _onChanged(tag);
                    },
                  ),
              ],
            ),
          ],
          if (widget.tags != null && widget.tags!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              'Existing tags',
              style: Theme.of(context).textTheme.labelMedium,
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in widget.tags!)
                  TagChip(
                    key: ValueKey('suggest-$tag'),
                    label: tag,
                    onPressed: () => _submit(tag),
                  ),
              ],
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          key: const ValueKey('confirm-tag-name'),
          onPressed: () => _submit(_controller.text),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

/// A searchable picker dialog that shows only existing [tags] (the union of
/// tags present on the selected documents) and forces the user to pick one.
/// Unlike [_TagNameDialog] there is no free-text input — every accepted value
/// is guaranteed to be an already-used tag.
class _ExistingTagDialog extends StatefulWidget {
  const _ExistingTagDialog({required this.tags});

  /// Pre-sorted list of tags that exist on at least one selected document.
  final List<String> tags;

  @override
  State<_ExistingTagDialog> createState() => _ExistingTagDialogState();
}

class _ExistingTagDialogState extends State<_ExistingTagDialog> {
  late final TextEditingController _controller = TextEditingController();
  List<String> _filtered = [];

  @override
  void initState() {
    super.initState();
    _filtered = widget.tags;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _applyFilter(String query) {
    final q = query.trim().toLowerCase();
    setState(() {
      _filtered = q.isEmpty
          ? widget.tags
          : widget.tags.where((t) => t.toLowerCase().contains(q)).toList();
    });
  }

  @override
  Widget build(BuildContext context) {
    final noneMatch =
        _controller.text.trim().isNotEmpty && _filtered.isEmpty;
    return AlertDialog(
      title: const Text('Remove tag'),
      content: SizedBox(
        width: 320,
        height: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _controller,
              autofocus: true,
              decoration: const InputDecoration(
                labelText: 'Search tags',
                prefixIcon: Icon(Icons.search, size: 18),
                border: OutlineInputBorder(),
              ),
              onChanged: _applyFilter,
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _filtered.isEmpty
                  ? Center(
                      child: Text(
                        noneMatch ? 'No matching tag' : 'No tags in selection',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: _filtered.length,
                      itemBuilder: (context, index) {
                        final tag = _filtered[index];
                        return ListTile(
                          dense: true,
                          leading: const Icon(Icons.tag, size: 16),
                          title: Text(tag),
                          onTap: () => Navigator.of(context).pop(tag),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }
}

/// A broadcast-ready progress snapshot for the bulk suggest pass.
class CountProgress {
  const CountProgress({this.label = '', this.completed = 0, this.total = 0});

  /// Human-readable label, e.g. "Suggesting titles…".
  final String label;

  /// Documents finished so far.
  final int completed;

  /// Total documents in the pass.
  final int total;

  bool get active => total > 0 && completed < total;
}

/// A `ValueNotifier`-backed progress reporter so the corner progress chip can
/// rebuild independently of the grid.
class CountNotifier extends ValueNotifier<CountProgress> {
  CountNotifier() : super(const CountProgress());

  /// Whether a bulk suggest pass is in flight (non-zero total, not yet done).
  bool get active => value.active;

  String get label => value.label;
  set label(String v) => value = CountProgress(
    label: v,
    completed: value.completed,
    total: value.total,
  );

  int get completed => value.completed;
  set completed(int v) => value = CountProgress(
    label: value.label,
    completed: v,
    total: value.total,
  );

  int get total => value.total;
  set total(int v) => value = CountProgress(
    label: value.label,
    completed: value.completed,
    total: v,
  );
}

/// A compact icon-only toolbar button for the selection bar.
class _BulkToolbarAction extends StatelessWidget {
  const _BulkToolbarAction({
    super.key,
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = destructive ? scheme.error : null;
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      color: color,
      icon: Icon(icon),
    );
  }
}

/// The document preview (image / PDF first page / type-colored placeholder)
/// fills the whole tile. A bottom gradient scrim keeps the title readable
/// regardless of the image; the document's tags are overlaid near the top as
/// compact dark-translucent chips (readable over arbitrary preview content).
class _DocumentPreviewTile extends StatelessWidget {
  const _DocumentPreviewTile({
    required this.document,
    required this.loader,
    required this.onTapTile,
    required this.onLongPress,
    this.selectionMode = false,
    this.selected = false,
    this.onCheckboxTap,
    this.onTagTap,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;

  /// Invoked when the tile is tapped: opens the document in browse mode, or
  /// toggles selection in selection mode.
  final VoidCallback onTapTile;

  /// Invoked when the always-visible select checkbox is tapped: in browse
  /// mode this enters selection mode with this tile pre-selected; in selection
  /// mode it toggles selection. Never opens the document.
  final VoidCallback? onCheckboxTap;

  /// Invoked on long-press (always enters selection mode with this tile
  /// pre-selected).
  final VoidCallback onLongPress;

  /// Whether the grid is in selection mode (routes taps to selection toggling
  /// and shows the primary-tinted overlay wash).
  final bool selectionMode;

  /// Whether this tile's document is currently selected.
  final bool selected;

  /// Called when a tag chip on the preview overlay is tapped. The argument is
  /// the tag name. Tapping a tag toggles it in the filter bar (adds if absent,
  /// removes if already active) without opening the document.
  final ValueChanged<String>? onTagTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      clipBehavior: Clip.antiAlias,
      shape: selected
          ? RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: scheme.primary, width: 2),
            )
          : null,
      child: InkWell(
        onTap: onTapTile,
        onLongPress: onLongPress,
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
            if (selectionMode)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: scheme.primary.withValues(alpha: 0.18),
                  ),
                ),
              ),
            if (document.tags.isNotEmpty)
              Positioned(
                top: 8,
                left: 8,
                right: 8,
                child: Wrap(
                  spacing: 4,
                  runSpacing: 4,
                  children: [
                    for (final tag in maximalTags(document.tags))
                      TagChip(
                        // Tapping the chip toggles it in the filter bar; the
                        // handler lives on TagChip itself so the pill is
                        // interactive (tap-only: no hover lightening, no click
                        // cursor) and its tap never falls through to the
                        // tile's open-document InkWell below.
                        key: ValueKey('tile-tag-tap-$tag'),
                        label: tag,
                        onPressed: onTagTap != null
                            ? () => onTagTap!(tag)
                            : null,
                      ),
                  ],
                ),
              ),
            // Title pinned above the corner checkbox: the right inset reserves
            // the checkbox zone so the label never runs beneath the square.
            Positioned(
              left: 10,
              right: 48,
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
            // Always-visible select checkbox inset slightly from the corner and
            // painted last so it stays tappable over the scrim/title. No backdrop
            // circle: the unchecked box renders transparently, and the bottom
            // scrim keeps the checked state readable over any preview content.
            Positioned(
              bottom: 4,
              right: 4,
              child: Checkbox(
                key: ValueKey('select-check-${document.id}'),
                value: selectionMode ? selected : false,
                onChanged: (_) => onCheckboxTap?.call(),
                visualDensity: VisualDensity.compact,
                side: const BorderSide(color: Color(0xFFE6E1E5), width: 1.6),
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

/// The grouping-order editor bottom sheet: a reorderable list of the property
/// keys to group the hierarchy by.  Dragging items changes the order; the
/// "Apply" button pops with the current order (or `null` on cancel via
/// dismiss).
class _HierarchyOrderSheet extends StatefulWidget {
  const _HierarchyOrderSheet({required this.initialOrder});

  /// The current grouping order (may be empty/outdated vs. the scope's key
  /// union — the sheet displays exactly these keys).
  final List<String> initialOrder;

  @override
  State<_HierarchyOrderSheet> createState() => _HierarchyOrderSheetState();
}

class _HierarchyOrderSheetState extends State<_HierarchyOrderSheet> {
  late final List<String> _keys = List.of(widget.initialOrder);

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SizedBox(
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Grouping order',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
            Expanded(
              child: ReorderableListView(
                key: const ValueKey('hier-order-sheet'),
                buildDefaultDragHandles: true,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                children: [
                  for (final key in _keys)
                    ListTile(
                      key: ValueKey('hier-order-item-$key'),
                      dense: true,
                      title: Text(key),
                    ),
                ],
                onReorderItem: (oldIndex, newIndex) {
                  setState(() {
                    final key = _keys.removeAt(oldIndex);
                    _keys.insert(newIndex, key);
                  });
                },
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: FilledButton(
                key: const ValueKey('hier-order-apply'),
                onPressed: () => Navigator.of(context).pop(List.of(_keys)),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
