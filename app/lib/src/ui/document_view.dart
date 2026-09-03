import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:url_launcher/url_launcher.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart' show DocumentService;
import 'document_preview_view.dart' show DocumentPreviewPanel;
import 'widgets.dart' show TagChip;

/// How many one-tap "existing tag" suggestions the add-tag composer shows at
/// most (kept small for the dense detail-view layout).
const int kAddTagSuggestionLimit = 8;

/// A compact summary of a document enough to open it in a detail view.
///
/// Shared by the search results and the chat citations so both can hand a
/// document to [DocumentDetailView].
class DocumentSummary {
  const DocumentSummary({
    required this.id,
    required this.title,
    this.snippet,
    this.tags = const [],
    this.paths = const [],
    this.mimeType,
    this.originalName,
    this.extra = const {},
  });

  final String id;
  final String title;
  final String? snippet;
  final List<String> tags;
  final List<String> paths;

  /// MIME type of the original file, when known (used to derive a temp-file
  /// extension for the "open externally" action, and to decide whether the raw
  /// bytes can be decoded as text in the built-in viewer).
  final String? mimeType;

  /// Original file name recorded at ingestion (`extra['original_name']`), when
  /// known. Its extension gives the best hint for the default system handler.
  final String? originalName;

  /// The document's extensible key/value metadata (`extra` on the repository
  /// `Document`). The detail view consults `extra['title_manual']` and
  /// `extra['tags_manual']` (when present) before blindly applying the
  /// auto-organization suggestions so a user's manual edits are never
  /// overwritten.
  final Map<String, String> extra;

  /// Whether the title has been hand-edited by the user (companion storage
  /// task sets `extra['title_manual'] = 'true'` on manual rename).
  bool get titleManuallyEdited => extra['title_manual'] == 'true';

  /// Whether the tags have been hand-edited by the user (companion storage
  /// task sets `extra['tags_manual'] = 'true'` on manual tag edits).
  bool get tagsManuallyEdited => extra['tags_manual'] == 'true';
}

/// A full-screen (or right-side panel) detail view for a document opened from
/// a search result, the browse list, or a chat citation.
///
/// Loads the full extracted content through [DocumentService] (falling back to
/// a UTF-8 decode of the raw bytes for text documents), renders the metadata
/// with an inline-editable title and editable tags, can suggest title + tags
/// through the existing auto-org pipeline, and can hand the raw bytes to the
/// system default handler via an injectable [ExternalFileOpener] (defaults to
/// a `url_launcher`-backed implementation).
class DocumentDetailView extends StatefulWidget {
  const DocumentDetailView({
    super.key,
    required this.document,
    required this.documentService,
    this.onBack,
    this.openExternally = openExternallyWithUrlLauncher,
    this.tempDirectory = getTemporaryDirectory,
    this.previewLoader,
    this.onMetaChanged,
  });

  final DocumentSummary document;
  final DocumentService documentService;
  final VoidCallback? onBack;

  /// Opens a local file with the platform's default handler. Injectable so
  /// widget tests never touch the `url_launcher` platform channel.
  final ExternalFileOpener openExternally;

  /// Where the temp copy for the external opener is written. Injectable so
  /// widget tests never touch the `path_provider` platform channel.
  final Future<Directory> Function() tempDirectory;

  /// The preview loader for the in-detail image/PDF panel. Defaults to a
  /// loader bound to [documentService]; injectable so widget tests can swap in
  /// a synchronous (isolate-free) thumbnailer.
  final DocumentPreviewLoader? previewLoader;

  /// Called whenever the document's meta-info (title, tags) changes so the
  /// parent can refresh stale preview tiles (e.g. the Documents browse grid).
  final VoidCallback? onMetaChanged;

  @override
  State<DocumentDetailView> createState() => _DocumentDetailViewState();
}

/// How a temp file is handed to the OS default application.
typedef ExternalFileOpener = Future<void> Function(String path);

/// Default opener: `launchUrl` the file URI with the OS default handler.
///
/// Works on desktop (macOS/Linux/Windows) and drops to a [StateError] on
/// platforms where a `file://` URI cannot be opened directly.
Future<void> openExternallyWithUrlLauncher(String path) async {
  final uri = Uri.file(path);
  if (!await launchUrl(uri)) {
    throw StateError('No default application could open $uri');
  }
}

/// State that loads full content, edits metadata, and hands bytes to the OS.
class _DocumentDetailViewState extends State<DocumentDetailView> {
  late DocumentSummary _doc;
  String? _content;
  bool _loadingContent = true;
  Object? _contentError;

  /// Whether the title suggestion (magic wand) is running in the background.
  bool _suggestingTitle = false;

  /// Whether the tags suggestion is running in the background.
  bool _suggestingTags = false;

  /// Monotonic generation for tag persistence. Each optimistic tag change
  /// bumps it; a background persist only applies when it is still the latest,
  /// so out-of-order completions never clobber a newer local state.
  int _tagsGeneration = 0;

  /// The tag names suggested by the last [DocumentService.suggestTags] run, so
  /// the add-tag composer can offer them as one-tap chips.
  List<String> _lastSuggestedTags = const [];

  late final TextEditingController _titleController;

  /// Shared preview loader backed by the document service; reuses the same LRU
  /// cache as the browse/search thumbnails so the detail panel doesn't re-read
  /// bytes the list already loaded. Injectable via [DocumentDetailView.previewLoader]
  /// (tests swap in a synchronous thumbnailer).
  late final DocumentPreviewLoader _previewLoader =
      widget.previewLoader ??
      DocumentPreviewLoader(
        bytesSource: (id) => widget.documentService.readBytes(id),
      );

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _titleController = TextEditingController(text: widget.document.title);
    _load();
  }

  @override
  void dispose() {
    _titleController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loadingContent = true;
      _contentError = null;
    });
    try {
      final doc = await widget.documentService.getDocument(widget.document.id);
      // Prefer the extracted text; fall back to a UTF-8 decode of the raw bytes
      // for plain-text documents so the viewer works even before extraction.
      var content = await widget.documentService.getContent(widget.document.id);
      if ((content == null || content.isEmpty) && _isTextLike(doc)) {
        final bytes = await widget.documentService.readBytes(
          widget.document.id,
        );
        content = utf8.decode(bytes, allowMalformed: true);
      }
      if (!mounted) return;
      setState(() {
        _doc = doc;
        // Mirror a persisted rename into the inline field (e.g. a refresh after
        // a tag edit re-loads the document).
        if (_titleController.text.isNotEmpty &&
            doc.title != widget.document.title &&
            doc.title.isNotEmpty) {
          _titleController.text = doc.title;
        }
        _content = content;
        _loadingContent = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _contentError = e;
        _loadingContent = false;
      });
    }
  }

  bool _isTextLike(DocumentSummary doc) {
    final mime = doc.mimeType ?? '';
    return mime.startsWith('text/') ||
        mime.contains('json') ||
        mime.contains('xml') ||
        mime.contains('csv');
  }

  /// Optimistically apply a new tag set to [nextTags], persist it in the
  /// background, and revert the local change (with an error snackbar) if the
  /// persist fails.
  ///
  /// The UI never awaits the bridge round-trip: [nextTags] appears instantly.
  /// A monotonic [_tagsGeneration] guards against out-of-order completions, so
  /// a stale (older) persist completing later never overwrites a newer local
  /// state — only the failure of the *latest* persist reverts the UI.
  void _applyTagsOptimistically(List<String> nextTags) {
    if (nextTags.toSet().length != nextTags.length) return;
    final previous = List.of(_doc.tags);
    final generation = ++_tagsGeneration;
    setState(() {
      _doc = _copyDoc(_doc, tags: List.of(nextTags));
    });
    widget.onMetaChanged?.call();
    unawaited(_persistTags(previous, nextTags, generation));
  }

  Future<void> _persistTags(
    List<String> previous,
    List<String> nextTags,
    int generation,
  ) async {
    try {
      await widget.documentService.setTags(widget.document.id, nextTags);
      if (!mounted || generation != _tagsGeneration) return;
    } catch (e) {
      if (!mounted || generation != _tagsGeneration) return;
      setState(() {
        _doc = _copyDoc(_doc, tags: previous);
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update tags: $e')));
    }
  }

  Future<void> _saveTitle(String value) async {
    final title = value.trim();
    if (title.isEmpty || title == _doc.title) return;
    try {
      await widget.documentService.updateTitle(widget.document.id, title);
      final fresh = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      setState(() {
        _doc = fresh;
        _titleController.text = fresh.title;
      });
      widget.onMetaChanged?.call();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Title updated')));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update title: $e')));
    }
  }

  /// Trigger the split "Suggest title" action (magic wand) asynchronously.
  ///
  /// Kicks off [DocumentService.suggestTitle] in the background (the service
  /// offloads the deterministic organizer to a compute/isolate work item, so
  /// the UI isolate is never blocked), applies the suggestion when the user has
  /// not manually renamed the document, and reports the outcome in a snackbar.
  Future<void> _suggestTitle() async {
    if (_suggestingTitle) return;
    // Capture the pre-run flags: the store marks `title_manual` when it applies
    // the suggestion, so we must remember whether the user had *already* edited
    // before reporting "unchanged (manually edited)".
    final alreadyManual = _doc.titleManuallyEdited;
    final previousTitle = _doc.title;
    setState(() => _suggestingTitle = true);
    try {
      final plan = await widget.documentService.suggestTitle(
        widget.document.id,
      );
      final fresh = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      final applied = fresh.title != previousTitle;
      setState(() {
        _doc = fresh;
        _titleController.text = fresh.title;
        _suggestingTitle = false;
      });
      widget.onMetaChanged?.call();
      final clean = plan.cleanTitle;
      if (clean != null && applied) {
        // Small confirmation: title was actually suggested & applied.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Title suggested: $clean')));
      } else if (alreadyManual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Title unchanged (manually edited)')),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No title suggestion')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _suggestingTitle = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not suggest title: $e')));
    }
  }

  /// Trigger the split "Suggest tags" action asynchronously.
  ///
  /// Kicks off [DocumentService.suggestTags] in the background (non-blocking),
  /// applies the suggested tags when the user has not manually tagged the
  /// document, and reports the outcome in a snackbar. The fresh tags are also
  /// cached so the add-tag composer can offer them as one-tap suggestions.
  Future<void> _suggestTags() async {
    if (_suggestingTags) return;
    // Capture the pre-run flags (see [_suggestTitle]: the store marks
    // `tags_manual` when it applies a suggestion).
    final alreadyManual = _doc.tagsManuallyEdited;
    setState(() => _suggestingTags = true);
    try {
      final plan = await widget.documentService.suggestTags(widget.document.id);
      final fresh = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      setState(() {
        _doc = fresh;
        _suggestingTags = false;
        _lastSuggestedTags = List.of(plan.tags);
      });
      widget.onMetaChanged?.call();
      if (plan.tags.isNotEmpty && !alreadyManual) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Tags suggested: ${plan.tags.join(', ')}')),
        );
      } else if (alreadyManual) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Tags unchanged (manually edited)')),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('No tags suggested')));
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _suggestingTags = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not suggest tags: $e')));
    }
  }

  /// A document copy with a replaced tag set. Keeps the rest of the summary
  /// (including the `extra` manual-edit metadata) intact.
  DocumentSummary _copyDoc(DocumentSummary src, {required List<String> tags}) =>
      DocumentSummary(
        id: src.id,
        title: src.title,
        snippet: src.snippet,
        tags: List.of(tags),
        paths: src.paths,
        mimeType: src.mimeType,
        originalName: src.originalName,
        extra: src.extra,
      );

  Future<void> _openExternally() async {
    try {
      final bytes = await widget.documentService.readBytes(widget.document.id);
      if (bytes.isEmpty) {
        throw StateError('Document has no raw bytes to open');
      }
      final suffix = _fileSuffix();
      var dir = await widget.tempDirectory();
      if (!await dir.exists()) {
        // The injected directory may be a path whose parent does not exist
        // (e.g. a deleted /tmp subfolder), or was never created. Create it;
        // fall back to `Directory.systemTemp` when that fails so "open
        // externally" degrades gracefully instead of throwing a
        // PathNotFoundException on the later `File.writeAsBytes`.
        try {
          await dir.create(recursive: true);
        } catch (_) {
          dir = Directory.systemTemp;
        }
      }
      final safeBase = _safeBaseName();
      final path = '${dir.path}/$safeBase$suffix';
      await File(path).writeAsBytes(bytes, flush: true);
      await widget.openExternally(path);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not open externally: $e')));
    }
  }

  /// A filesystem-safe base name derived from the original file name or id.
  String _safeBaseName() {
    final raw = _doc.originalName ?? 'document-${_doc.id}';
    final base = raw.split('/').last.split('\\').last;
    final sanitized = base
        .replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_')
        .replaceAll(RegExp(r'^[_\\.]+'), '')
        .replaceAll(RegExp(r'[_\\.]+$'), '');
    return sanitized.isEmpty ? 'document-${_doc.id}' : sanitized;
  }

  /// Best-effort file extension for the temp copy: prefer the suffix of the
  /// original file name, otherwise map the MIME type.
  String _fileSuffix() {
    final name = _doc.originalName;
    if (name != null && name.isNotEmpty) {
      final dot = name.lastIndexOf('.');
      if (dot > 0 && dot < name.length - 1) {
        final ext = name.substring(dot);
        if (ext.length <= 10) return ext;
      }
    }
    final mime = _doc.mimeType;
    if (mime == null) return '';
    const map = <String, String>{
      'application/pdf': '.pdf',
      'text/plain': '.txt',
      'text/markdown': '.md',
      'image/png': '.png',
      'image/jpeg': '.jpg',
      'image/gif': '.gif',
      'image/bmp': '.bmp',
      'image/webp': '.webp',
      'message/rfc822': '.eml',
      'application/zip': '.zip',
    };
    return map[mime] ?? '';
  }

  /// Instantly (optimistically) add [tag] to the document's local tags and
  /// persist the new set in the background. No-op when the tag is blank or
  /// already present.
  void _addTag(String tag) {
    final clean = tag.trim();
    if (clean.isEmpty || _doc.tags.contains(clean)) return;
    _applyTagsOptimistically([..._doc.tags, clean]);
  }

  /// Instantly (optimistically) remove [tag] from the document's local tags and
  /// persist the new set in the background.
  void _removeTag(String tag) {
    if (!_doc.tags.contains(tag)) return;
    _applyTagsOptimistically(_doc.tags.where((e) => e != tag).toList());
  }

  /// Tag names the add-tag composer can one-tap: the last suggestion run plus
  /// every tag already known to the repository, filtered to ones not yet on
  /// this document. Kept compact (up to [kAddTagSuggestionLimit]).
  Future<List<String>> _composerTagSuggestions() async {
    final known = <String>{
      ..._lastSuggestedTags,
      ...await widget.documentService.listTags(),
    };
    final applied = _doc.tags.toSet();
    return known.where((t) => !applied.contains(t)).take(8).toList();
  }

  /// Opens the compact add-tag composer: a text field to name a brand-new tag
  /// and a Wrap of "existing but not yet applied" tags (from the last
  /// [DocumentService.suggestTags] run, or [DocumentService.listTags]) that can
  /// be applied instantly.
  Future<void> _openAddTagComposer() async {
    final suggestions = await _composerTagSuggestions();
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _AddTagComposerDialog(
        suggestions: suggestions,
        onSubmit: (tag) => _addTag(tag),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        toolbarHeight: 44,
        leading: widget.onBack == null
            ? null
            : IconButton(
                icon: const Icon(Icons.arrow_back),
                onPressed: widget.onBack,
              ),
        title: const Text('Document'),
        actions: [
          IconButton(
            tooltip: 'Open in default app',
            icon: const Icon(Icons.open_in_new),
            onPressed: _loadingContent ? null : _openExternally,
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 36,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(child: _buildTitleEditor()),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Text(
                        'Tags',
                        style: Theme.of(context).textTheme.titleSmall,
                      ),
                      const Spacer(),
                      // "Suggest tags" — the tag icon (sell) distinguishes it
                      // from the title-row magic wand while matching the
                      // bulk-selection toolbar's tag-suggest affordance.
                      if (_suggestingTags)
                        const Padding(
                          padding: EdgeInsets.all(8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child:
                                CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      else
                        IconButton(
                          tooltip: 'Suggest tags',
                          visualDensity: VisualDensity.compact,
                          onPressed:
                              _loadingContent ? null : _suggestTags,
                          icon: const Icon(
                            Icons.sell_outlined,
                            size: 20,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildTags(),
                  if (_doc.paths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildPaths(),
                  ],
                ],
              ),
            ),
          ),
          if (_isVisual(_doc)) ...[
            const SizedBox(height: 16),
            Text('Preview', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            DocumentPreviewPanel(
              key: ValueKey('preview-${_doc.id}'),
              document: _doc,
              loader: _previewLoader,
            ),
          ],
          const SizedBox(height: 16),
          Text('Content', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildContent(),
          const SizedBox(height: 48),
        ],
      ),
    );
  }

  /// Whether [doc] should show the visual preview panel (image or PDF).
  bool _isVisual(DocumentSummary doc) {
    final mime = (doc.mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return true;
    return mime == 'application/pdf' ||
        mime == 'application/x-pdf' ||
        mime == 'application/acrobat';
  }

  Widget _buildTitleEditor() {
    final suggestingTitle = _suggestingTitle;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _titleController,
            style: Theme.of(context).textTheme.headlineSmall,
            decoration: InputDecoration(
              hintText: 'Document title',
              isDense: true,
              border: InputBorder.none,
              contentPadding: const EdgeInsets.symmetric(vertical: 4),
            ),
            onSubmitted: _saveTitle,
          ),
        ),
        // Magic-wand "Suggest title": replaces the old 'Save title' button.
        // Runs asynchronously in the background — the UI is never blocked.
        if (suggestingTitle)
          const Padding(
            padding: EdgeInsets.all(8),
            child: SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          )
        else
          IconButton(
            tooltip: 'Suggest title',
            visualDensity: VisualDensity.compact,
            onPressed: _loadingContent ? null : _suggestTitle,
            icon: const Icon(Icons.auto_fix_high, size: 20),
          ),
      ],
    );
  }

  Widget _buildPaths() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final path in _doc.paths)
          Chip(
            avatar: const Icon(Icons.folder_outlined, size: 14),
            label: Text(path),
            visualDensity: VisualDensity.compact,
            // Explicit onSurfaceVariant (not the theme's chip default) so path
            // chips stay dark-on-light / light-on-dark instead of white-on-light.
            labelStyle: TextStyle(
              fontSize: 11.5,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
      ],
    );
  }

  /// Compact, deterministic-colored tag chips without the label icon. Editable
  /// in the detail view (delete to remove).
  ///
  /// Tag add/remove is optimistic: the chip disappears/appears instantly and
  /// the service persist runs in the background (reverting on failure).
  Widget _buildTags() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in _doc.tags)
          TagChip(
            key: ValueKey('tag-$tag'),
            label: tag,
            onDeleted: () => _removeTag(tag),
          ),
        // A plain "+" that opens the tag composer. A bare icon, no circle,
        // centered inside a box sized to the TagChip pills' height
        // (11.5px label + 2×5px padding + 2×1px border ≈ 24px) so it sits
        // optically centered against the chips instead of riding above them.
        // The Wrap's own spacing provides the horizontal gap. The tooltip
        // keeps the affordance discoverable for mouse users and labelled for
        // screen readers.
        Tooltip(
          message: 'Add tag',
          child: MouseRegion(
            cursor: SystemMouseCursors.click,
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: _openAddTagComposer,
              child: SizedBox(
                width: 24,
                height: 24,
                child: Icon(
                  Icons.add,
                  size: 18,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildContent() {
    if (_loadingContent) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    }
    if (_contentError != null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.error_outline,
                color: Theme.of(context).colorScheme.error,
              ),
              const SizedBox(height: 8),
              Text('Could not load content: $_contentError'),
            ],
          ),
        ),
      );
    }
    final content = _content;
    if (content == null || content.isEmpty) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text('No extracted content yet.'),
        ),
      );
    }
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: SelectableText(
          content,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(height: 1.5),
        ),
      ),
    );
  }
}

/// The compact add-tag composer dialog: a text field to name a brand-new tag
/// plus a Wrap of "existing but not yet applied" tags ([suggestions]) that can
/// be applied with a single tap.
///
/// This is a self-contained [StatefulWidget] so the [TextEditingController]
/// lives exactly as long as the dialog (created in [initState], disposed in
/// [dispose]) — avoiding "used after being disposed" crashes during the
/// dialog's exit animation.
class _AddTagComposerDialog extends StatefulWidget {
  const _AddTagComposerDialog({
    required this.suggestions,
    required this.onSubmit,
  });

  /// Tag names (from suggestTags or the repository) not yet applied to the
  /// document, offered as one-tap chips.
  final List<String> suggestions;

  /// Called with a trimmed tag name when the user confirms (Add button, Enter,
  /// or tapping a suggestion chip).
  final ValueChanged<String> onSubmit;

  @override
  State<_AddTagComposerDialog> createState() => _AddTagComposerDialogState();
}

class _AddTagComposerDialogState extends State<_AddTagComposerDialog> {
  late final TextEditingController _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String raw) {
    final tag = raw.trim();
    if (tag.isEmpty) return;
    Navigator.of(context).pop();
    widget.onSubmit(tag);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add tag'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 40,
                  child: TextField(
                    controller: _controller,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'New tag name…',
                      prefixIcon: Icon(Icons.tag, size: 18),
                      isDense: true,
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 8,
                      ),
                    ),
                    onSubmitted: _submit,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(
                tooltip: 'Add tag',
                visualDensity: VisualDensity.compact,
                onPressed: () => _submit(_controller.text),
                icon: const Icon(Icons.add),
              ),
            ],
          ),
          if (widget.suggestions.isNotEmpty) ...[
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
                for (final tag in widget.suggestions)
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
      ],
    );
  }
}
