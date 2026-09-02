import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:url_launcher/url_launcher.dart';

import '../features/document_preview.dart' show DocumentPreviewLoader;
import '../features/document_service.dart' show DocumentService;
import 'document_preview_view.dart' show DocumentPreviewPanel;
import 'widgets.dart' show TagDeleteIcon, tagColorFor, tagTintFor;

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
  bool _savingTags = false;
  bool _savingTitle = false;
  bool _suggesting = false;
  final _tagController = TextEditingController();
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
    _tagController.dispose();
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

  Future<void> _saveTags(List<String> tags) async {
    if (_savingTags || tags.toSet().length != tags.length) return;
    setState(() => _savingTags = true);
    try {
      await widget.documentService.setTags(widget.document.id, tags);
      final fresh = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      setState(() {
        _doc = fresh;
        _savingTags = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingTags = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update tags: $e')));
    }
  }

  Future<void> _saveTitle(String value) async {
    final title = value.trim();
    if (_savingTitle || title.isEmpty || title == _doc.title) return;
    setState(() => _savingTitle = true);
    try {
      await widget.documentService.updateTitle(widget.document.id, title);
      final fresh = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      setState(() {
        _doc = fresh;
        _titleController.text = fresh.title;
        _savingTitle = false;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Title updated')));
    } catch (e) {
      if (!mounted) return;
      setState(() => _savingTitle = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not update title: $e')));
    }
  }

  /// Runs the auto-organization bridge through the per-file re-organization
  /// variant ([DocumentService.reorganizeOne]), which honors the
  /// `title_manual`/`tags_manual` flags *inside the core*: a title is applied
  /// only when the user has *not* manually renamed it, and tags only when the
  /// user has *not* manually tagged the document. The core applies the changes
  /// and refreshes the search metadata; this view then re-reads the document
  /// so the UI reflects whatever was applied.
  Future<void> _suggestMetadata() async {
    if (_suggesting) return;
    setState(() => _suggesting = true);
    try {
      await widget.documentService.reorganizeOne(widget.document.id);
      final refreshed = await widget.documentService.getDocument(
        widget.document.id,
      );
      if (!mounted) return;
      final changed =
          refreshed.title != _doc.title ||
          refreshed.tags.join('\u0000') != _doc.tags.join('\u0000');
      setState(() {
        _doc = refreshed;
        _titleController.text = refreshed.title;
        _suggesting = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            changed
                ? 'Suggested title & tags applied'
                : 'No new suggestions to apply',
          ),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _suggesting = false);
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Could not suggest metadata: $e')));
    }
  }

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

  void _addTag(String value) {
    final tag = value.trim();
    if (tag.isEmpty) return;
    if (_doc.tags.contains(tag)) {
      _tagController.clear();
      return;
    }
    final next = [..._doc.tags, tag];
    _tagController.clear();
    _saveTags(next);
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
          IconButton(
            tooltip: 'Close',
            icon: const Icon(Icons.close),
            onPressed: widget.onBack,
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
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonalIcon(
                      onPressed: _suggesting || _loadingContent
                          ? null
                          : _suggestMetadata,
                      icon: _suggesting
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_fix_high, size: 16),
                      label: Text(
                        _suggesting ? 'Suggesting…' : 'Suggest title & tags',
                      ),
                      style: FilledButton.styleFrom(
                        visualDensity: VisualDensity.compact,
                        padding: const EdgeInsets.symmetric(horizontal: 10),
                        textStyle: const TextStyle(fontSize: 12.5),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Text('Tags', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 6),
                  _buildTags(),
                  if (_doc.paths.isNotEmpty) ...[
                    const SizedBox(height: 12),
                    _buildPaths(),
                  ],
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 40,
                          child: TextField(
                            controller: _tagController,
                            enabled: !_savingTags,
                            decoration: const InputDecoration(
                              hintText: 'Add a tag…',
                              prefixIcon: Icon(Icons.tag, size: 18),
                              isDense: true,
                              border: OutlineInputBorder(),
                              contentPadding: EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 8,
                              ),
                            ),
                            onSubmitted: _addTag,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Add tag',
                        visualDensity: VisualDensity.compact,
                        onPressed: _savingTags
                            ? null
                            : () => _addTag(_tagController.text),
                        icon: const Icon(Icons.add),
                      ),
                    ],
                  ),
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
    final busy = _savingTitle;
    return Row(
      children: [
        Expanded(
          child: TextField(
            controller: _titleController,
            enabled: !busy,
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
        if (busy)
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
            tooltip: 'Save title',
            visualDensity: VisualDensity.compact,
            onPressed: () => _saveTitle(_titleController.text),
            icon: const Icon(Icons.check, size: 20),
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
  Widget _buildTags() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in _doc.tags)
          InputChip(
            key: ValueKey('tag-$tag'),
            label: Text(tag),
            visualDensity: VisualDensity.compact,
            labelStyle: Theme.of(context).textTheme.labelSmall,
            backgroundColor: tagTintFor(context, tag),
            side: BorderSide(color: tagColorFor(tag).withValues(alpha: 0.45)),
            deleteIcon: _savingTags
                ? null
                : TagDeleteIcon(color: tagColorFor(tag)),
            deleteIconColor: tagColorFor(tag),
            onDeleted: _savingTags
                ? null
                : () => _saveTags(_doc.tags.where((e) => e != tag).toList()),
          ),
        if (_savingTags)
          const SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
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
