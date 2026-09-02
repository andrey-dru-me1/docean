import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart' show getTemporaryDirectory;
import 'package:url_launcher/url_launcher.dart';

import '../features/document_service.dart' show DocumentService;

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
}

/// A full-screen detail view for a document opened from a search result or a
/// chat citation.
///
/// Loads the full extracted content through [DocumentService] (falling back to
/// a UTF-8 decode of the raw bytes for text documents), renders the metadata
/// with editable tags, and can hand the raw bytes to the system default handler
/// via an injectable [ExternalFileOpener] (defaults to a `url_launcher`-backed
/// implementation).
class DocumentDetailView extends StatefulWidget {
  const DocumentDetailView({
    super.key,
    required this.document,
    required this.documentService,
    this.onBack,
    this.openExternally = openExternallyWithUrlLauncher,
    this.tempDirectory = getTemporaryDirectory,
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

/// State that loads full content, edits tags, and hands bytes to the OS.
class _DocumentDetailViewState extends State<DocumentDetailView> {
  late DocumentSummary _doc;
  String? _content;
  bool _loadingContent = true;
  Object? _contentError;
  bool _savingTags = false;
  final _tagController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _doc = widget.document;
    _load();
  }

  @override
  void dispose() {
    _tagController.dispose();
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

  Future<void> _openExternally() async {
    try {
      final bytes = await widget.documentService.readBytes(widget.document.id);
      final suffix = _fileSuffix();
      final dir = await widget.tempDirectory();
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
        .replaceAll(RegExp(r'^[_\.]+'), '')
        .replaceAll(RegExp(r'[_\.]+$'), '');
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
                    children: [
                      Icon(
                        Icons.description_outlined,
                        size: 40,
                        color: scheme.primary,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          _doc.title,
                          style: Theme.of(context).textTheme.headlineSmall,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'ID: ${_doc.id}',
                    style: Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(color: scheme.outline),
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
                          height: 44,
                          child: TextField(
                            controller: _tagController,
                            enabled: !_savingTags,
                            decoration: const InputDecoration(
                              hintText: 'Add a tag…',
                              prefixIcon: Icon(Icons.tag),
                              isDense: true,
                              border: OutlineInputBorder(),
                            ),
                            onSubmitted: _addTag,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton.filled(
                        tooltip: 'Add tag',
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
          const SizedBox(height: 16),
          Text('Content', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          _buildContent(),
          const SizedBox(height: 48),
        ],
      ),
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
          ),
      ],
    );
  }

  Widget _buildTags() {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final tag in _doc.tags)
          InputChip(
            key: ValueKey('tag-$tag'),
            avatar: const Icon(Icons.label_outline, size: 14),
            label: Text(tag),
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
