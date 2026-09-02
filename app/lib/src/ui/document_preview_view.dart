/// Rendering half of the document preview feature.
///
/// This file owns the widgets that *show* a preview produced by
/// [`DocumentPreviewLoader`](document_preview.dart):
///
/// * [DocumentThumbnail] — a small square preview for the Documents browse
///   list and search results (image bytes, PDF first page, or a MIME/extension
///   glyph on a deterministic colored tile).
/// * [DocumentPreviewPanel] — a larger preview for the document detail view
///   (image or PDF first page; text/other documents keep the content viewer).
///
/// Both are deliberately stateful so the async load has a home, and both go
/// through [DocumentPreviewLoader]'s shared LRU cache, so the list, search
/// results, and the detail panel reuse one load per document. Every failure
/// path degrades to [DocumentPlaceholder] — a preview can never brick the
/// surrounding UI.
library;

import 'package:flutter/material.dart';

import '../features/document_preview.dart'
    show
        DocumentPreview,
        DocumentPreviewFallback,
        DocumentPreviewImage,
        DocumentPreviewLoader,
        DocumentPreviewPdf;
import 'document_view.dart' show DocumentSummary;

/// A deterministic color for a document type, derived from its MIME type (or
/// original file extension when the MIME type is unknown).
///
/// The string is hashed (FNV-1a over its code units) onto a small palette of
/// material-shade colors, the same pattern as [tagColorFor] in `widgets.dart`.
Color previewColorFor(DocumentSummary document) {
  final name = document.mimeType ?? document.originalName ?? document.id;
  var hash = 0x811c9dc5;
  for (final unit in name.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return kPreviewPalette[hash % kPreviewPalette.length];
}

/// A curated palette of document-type colors (shade 600/700 material colors so
/// the white glyph stays readable on both light and dark themes).
const List<Color> kPreviewPalette = <Color>[
  Color(0xFF1E88E5), // blue 600
  Color(0xFF43A047), // green 600
  Color(0xFFFB8C00), // orange 600
  Color(0xFF8E24AA), // purple 600
  Color(0xFFE53935), // red 600
  Color(0xFF00897B), // teal 600
  Color(0xFF3949AB), // indigo 600
  Color(0xFFD81B60), // pink 600
  Color(0xFF6D4C41), // brown 600
  Color(0xFF00ACC1), // cyan 600
];

/// The glyph shown for a document whose type has no visual preview (e.g. text,
/// spreadsheets, zip). Derived deterministically from the MIME type.
IconData previewGlyphFor(DocumentSummary document) {
  final mime = (document.mimeType ?? '').toLowerCase();
  if (mime.startsWith('text/')) return Icons.description_outlined;
  if (mime.contains('csv') ||
      mime.contains('excel') ||
      mime.contains('spreadsheet')) {
    return Icons.table_chart_outlined;
  }
  if (mime.contains('json') || mime.contains('xml')) {
    return Icons.code;
  }
  if (mime == 'application/zip' ||
      mime.contains('compressed') ||
      mime.contains('archive')) {
    return Icons.folder_zip_outlined;
  }
  if (mime.contains('audio/') || mime == 'application/octet-stream') {
    return Icons.audiotrack_outlined;
  }
  if (mime.contains('video/')) return Icons.movie_outlined;
  return Icons.insert_drive_file_outlined;
}

/// The eternal fallback: a colored tile with a MIME-derived glyph. Used for
/// text/other documents by design, and for image/PDF docs whose preview
/// pipeline failed (so a failure never bricks the list/detail).
class DocumentPlaceholder extends StatelessWidget {
  const DocumentPlaceholder({
    super.key,
    required this.document,
    this.iconSize = 28,
    this.borderRadius = 8,
  });

  final DocumentSummary document;
  final double iconSize;
  final double borderRadius;

  @override
  Widget build(BuildContext context) {
    final color = previewColorFor(document);
    return DecoratedBox(
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Center(
        child: Icon(previewGlyphFor(document), size: iconSize, color: color),
      ),
    );
  }
}

/// A small square thumbnail for a document in a list.
///
/// Loads through [DocumentPreviewLoader]'s shared cache: while loading it shows
/// the type-colored placeholder tile (so the list doesn't jump when the
/// preview resolves), then swaps in the image (or PDF first page / fallback
/// glyph) when ready. Failed loads degrade to [DocumentPlaceholder] so the
/// list card is never broken.
class DocumentThumbnail extends StatefulWidget {
  const DocumentThumbnail({
    super.key,
    required this.document,
    required this.loader,
    this.size = 48,
    this.borderRadius = 8,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;

  /// The square edge length (defaults to 48 px list thumbnail).
  final double size;
  final double borderRadius;

  @override
  State<DocumentThumbnail> createState() => _DocumentThumbnailState();
}

class _DocumentThumbnailState extends State<DocumentThumbnail> {
  DocumentPreview? _preview;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DocumentThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id ||
        oldWidget.loader != widget.loader) {
      _load();
    }
  }

  Future<void> _load() async {
    final cached = widget.loader.cache[widget.document.id];
    if (cached is DocumentPreview &&
        (cached is DocumentPreviewImage || cached is DocumentPreviewPdf)) {
      if (mounted) setState(() => _preview = cached);
      return;
    }
    if (_loading) return;
    setState(() {
      _loading = true;
      _preview = null;
    });
    try {
      final result = await widget.loader.previewFor(widget.document);
      if (!mounted) return;
      setState(() {
        _preview = result;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _preview = const DocumentPreviewFallback();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final preview = _preview;
    if (_loading || preview == null) {
      // A loading tile mirrors the placeholder layout so the list doesn't
      // jump when the preview resolves.
      return SizedBox(
        width: size,
        height: size,
        child: DocumentPlaceholder(
          document: widget.document,
          iconSize: size * 0.4,
          borderRadius: widget.borderRadius,
        ),
      );
    }
    if (preview is DocumentPreviewImage) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            preview.bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _FallbackTile(document: widget.document),
          ),
        ),
      );
    }
    if (preview is DocumentPreviewPdf) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(widget.borderRadius),
        child: SizedBox(
          width: size,
          height: size,
          child: Image.memory(
            preview.pdfThumbnail.bytes,
            fit: BoxFit.cover,
            gaplessPlayback: true,
            errorBuilder: (_, _, _) => _FallbackTile(document: widget.document),
          ),
        ),
      );
    }
    return SizedBox(
      width: size,
      height: size,
      child: DocumentPlaceholder(
        document: widget.document,
        iconSize: size * 0.4,
        borderRadius: widget.borderRadius,
      ),
    );
  }
}

/// The inner fallback tile used when an image/PDF preview bytes fail to decode
/// inside [Image.memory] (belt-and-suspenders on top of the loader fallback).
class _FallbackTile extends StatelessWidget {
  const _FallbackTile({required this.document});

  final DocumentSummary document;

  @override
  Widget build(BuildContext context) => DocumentPlaceholder(document: document);
}

/// A larger preview panel for the document detail view.
///
/// Shows a real visual preview for image/PDF documents; for text/other (and
/// for preview pipelines that failed) it returns `null` so the detail view
/// keeps its existing text content viewer instead of a dead tile.
class DocumentPreviewPanel extends StatefulWidget {
  const DocumentPreviewPanel({
    super.key,
    required this.document,
    required this.loader,
  });

  final DocumentSummary document;
  final DocumentPreviewLoader loader;

  @override
  State<DocumentPreviewPanel> createState() => _DocumentPreviewPanelState();
}

class _DocumentPreviewPanelState extends State<DocumentPreviewPanel> {
  DocumentPreview? _preview;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DocumentPreviewPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.document.id != widget.document.id ||
        oldWidget.loader != widget.loader) {
      _load();
    }
  }

  Future<void> _load() async {
    try {
      final result = await widget.loader.previewFor(widget.document);
      if (!mounted) return;
      setState(() => _preview = result);
    } catch (_) {
      if (!mounted) return;
      setState(() => _preview = const DocumentPreviewFallback());
    }
  }

  @override
  Widget build(BuildContext context) {
    final preview = _preview;
    if (preview is DocumentPreviewImage) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Image.memory(
              preview.bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              // If the (already-downscaled) PNG somehow fails to decode, fall
              // back to the type placeholder rather than a broken image frame.
              errorBuilder: (_, _, _) => DocumentPlaceholder(
                document: widget.document,
                iconSize: 48,
                borderRadius: 8,
              ),
            ),
          ),
        ),
      );
    }
    if (preview is DocumentPreviewPdf) {
      return Card(
        clipBehavior: Clip.antiAlias,
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Image.memory(
              preview.pdfThumbnail.bytes,
              fit: BoxFit.contain,
              gaplessPlayback: true,
              errorBuilder: (_, _, _) => DocumentPlaceholder(
                document: widget.document,
                iconSize: 48,
                borderRadius: 8,
              ),
            ),
          ),
        ),
      );
    }
    // Text/other docs (and failed previews) keep the content viewer.
    return const SizedBox.shrink();
  }
}
