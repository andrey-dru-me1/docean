import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart'
    show BulkOrganizer, DocumentService, NoopBulkOrganizer;
import 'document_preview_view.dart' show DocumentTilePreview;
import 'document_view.dart' show DocumentSummary;
import 'search_screen.dart' show DocumentOpener;
import 'widgets.dart' show EmptyState, TagChip;

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
      if (_tagFilters.isNotEmpty && !_tagFilters.any(d.tags.contains)) return false;
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
              SizedBox(
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
          return _DocumentPreviewTile(
            document: document,
            loader: _previewLoader,
            selectionMode: _selectionMode,
            selected: _selected.contains(document.id),
            onTapTile: _selectionMode
                ? () => _toggleSelected(document.id)
                : () => widget.onOpenDocument(document),
            onLongPress: () => _enterSelectionMode(document.id),
            onTagTap: _toggleTagFilter,
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

  /// Toggle a tag in the filter bar: clicking a tag that is already the active
  /// filter removes it; clicking a tag that is not active sets it as the filter.
  void _toggleTagFilter(String tag) {
    setState(() {
      _tagFilter = _tagFilter == tag ? null : tag;
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

  /// Whether _every_ currently-filtered document is selected.
  bool get _allFilteredSelected {
    final filtered = _filtered;
    return filtered.isNotEmpty &&
        filtered.every((d) => _selected.contains(d.id));
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
                onPressed: _busy ? null : _selectAllFiltered,
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
  /// honored, so this appends rather than replaces).
  Future<void> _bulkAddTag() async {
    final tag = await _promptForTag(context, title: 'Add tag');
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

  /// Prompts for a tag name and strips it from every selected document (batch
  /// [`DocumentService.bulkTags`] with only `remove`).
  Future<void> _bulkRemoveTag() async {
    final tag = await _promptForTag(context, title: 'Remove tag');
    if (tag == null || !mounted) return;
    final ids = List.of(_selected);
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
  /// [_suggestProgress] and the corner progress chip.
  Future<void> _runBulkSuggest({required bool titles}) async {
    final ids = List.of(_selected);
    if (ids.isEmpty || _suggestProgress.active) return;
    var done = 0;
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
      }
      if (!mounted) return;
      done++;
      setState(() => _suggestProgress.completed = done);
    }
    if (!mounted) return;
    _showSnack(
      context,
      titles
          ? 'Titles suggested for $done document${done == 1 ? '' : 's'}.'
          : 'Tags suggested for $done document${done == 1 ? '' : 's'}.',
    );
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
/// the user cancels).
Future<String?> _promptForTag(BuildContext context, {required String title}) =>
    showDialog<String>(
      context: context,
      builder: (dialogContext) => _TagNameDialog(title: title),
    );

/// A small stateful dialog that owns its [TextEditingController] for the
/// lifetime of the dialog (created in [initState], disposed in [dispose]) to
/// avoid "used after disposed" crashes during the exit animation.
class _TagNameDialog extends StatefulWidget {
  const _TagNameDialog({required this.title});

  final String title;

  @override
  State<_TagNameDialog> createState() => _TagNameDialogState();
}

class _TagNameDialogState extends State<_TagNameDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
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
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(
          labelText: 'Tag name',
          prefixIcon: Icon(Icons.tag, size: 18),
          border: OutlineInputBorder(),
        ),
        onSubmitted: _submit,
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
    this.onTagTap,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;

  /// Invoked when the tile (or its checkbox) is tapped: opens the document in
  /// browse mode, or toggles selection in selection mode. Tapping the
  /// always-visible checkbox in browse mode enters selection mode.
  final VoidCallback onTapTile;

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
            // Always-visible select checkbox in the bottom-right corner.
            Positioned(
              bottom: 36,
              right: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: scheme.surface.withValues(alpha: 0.85),
                  shape: BoxShape.circle,
                ),
                child: Checkbox(
                  key: ValueKey('select-check-${document.id}'),
                  value: selectionMode ? selected : false,
                  onChanged: (_) => onTapTile(),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ),
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
                    for (final tag in document.tags)
                      GestureDetector(
                        key: ValueKey('tile-tag-tap-$tag'),
                        onTap: onTagTap != null ? () => onTagTap!(tag) : null,
                        behavior: HitTestBehavior.opaque,
                        child: TagChip(
                          key: ValueKey('tile-tag-$tag'),
                          label: tag,
                          overlay: true,
                        ),
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
