/// In-memory visual previews for documents stored in the content-addressed
/// SQLite blob store.
///
/// This module is the *loading* half of the preview feature: it turns a
/// document's raw bytes into a cached, safely-downscaled image or an opened
/// PDF document, wrapped in [DocumentPreview] results. The rendering half
/// (thumbnails for the browse/search lists and the larger detail panel) lives
/// in [`ui/document_preview_view.dart`](../ui/document_preview_view.dart).
///
/// Responsibilities:
///
/// * **Cache**: loaded previews are keyed by `documentId` in a shared LRU
///   (`_DocumentPreviewCache`, default capacity 64) so the browse list, search
///   results, and the detail view all reuse one load instead of re-reading
///   bytes from the repository. Failed loads are recorded too, so a broken
///   document degrades to the icon placeholder without re-reading on every
///   rebuild.
/// * **Safety**: image decoding runs in an isolate (`compute`) and is
///   downscaled with `package:image` before any `dart:ui` decode, so a
///   multi-megapixel upload never OOMs the UI thread.
/// * **Graceful fallback**: every decode/read/PDF-open failure is caught and
///   surfaced as [DocumentPreviewFallback], and every input path is guarded
///   (bad MIME, empty bytes, missing thumbnailer), so a preview can never
///   brick the list or the detail view.
///
/// All decoding hooks are injectable so widget tests can exercise the full
/// image path with real `package:image` decode/encode without touching the
/// native bridge or the pdfx platform channel.
library;

import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;
import 'package:pdfx/pdfx.dart'
    show PdfDocument, PdfPageImage, PdfPageImageFormat, hasPdfSupport;

import '../ui/document_view.dart' show DocumentSummary;

/// A function that returns a document's raw bytes by id. Defaults to
/// `DocumentService.readBytes`; injectable in tests.
typedef ImageBytesSource = Future<List<int>> Function(String documentId);

/// Opens a PDF from raw bytes and renders its first page. Injectable so widget
/// tests never touch the native pdfx platform channel.
typedef PdfOpener = Future<PdfPageImage> Function(Uint8List bytes);

/// Whether PDF rendering is supported on this platform. Defaults to the real
/// pdfx support probe; injectable so tests can force the supported path.
typedef PdfSupportChecker = Future<bool> Function();

/// Downscales + re-encodes an image to a thumbnail as PNG bytes. Injectable so
/// tests can observe the exact downscale request; on production this runs on
/// the real [computeIsolatedThumbnail] (on the UI isolate in test bindings).
typedef ImageThumbnailer =
    Future<Uint8List?> Function({
      required Uint8List bytes,
      required int maxDim,
    });

/// Normalize arbitrary raw bytes (e.g. the `List<int>` returned by the bridge)
/// to the `Uint8List` the preview pipeline requires.
Uint8List _asBytes(List<int> raw) =>
    raw is Uint8List ? raw : Uint8List.fromList(raw);

/// Pure thumbnail computation meant to run on a background isolate via
/// [compute]. Returns PNG bytes (typically ~1–4 KB) instead of the raw decoded
/// image so the repeated [Image.memory] widget / cache never holds a
/// full-resolution bitmap. Returns `null` on any decode failure, so the caller
/// falls back to the icon placeholder.
Uint8List? computeIsolatedThumbnail(Uint8List bytes, int maxDim) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  // Guard against insanely small source dims (a 0x0 image) so the resize
  // arithmetic below never produces 0/negative targets.
  if (decoded.width <= 0 || decoded.height <= 0) return null;
  // Downscale only (never upscale) to `maxDim` on the long edge, preserving
  // aspect ratio. This is what keeps a 12k×8k photo at ~256 px for preview.
  final scale =
      (maxDim /
              (decoded.width > decoded.height ? decoded.width : decoded.height))
          .clamp(0.0, 1.0);
  final resized = img.copyResize(
    decoded,
    width: (decoded.width * scale).round(),
    height: (decoded.height * scale).round(),
    interpolation: img.Interpolation.average,
  );
  return Uint8List.fromList(img.encodePng(resized));
}

/// Production thumbnailer: run the pure [computeIsolatedThumbnail] on a
/// background isolate via `compute`. In test bindings `compute` runs on the
/// main isolate so images still render under FakeAsync.
Future<Uint8List?> computeIsolatedThumbnailInBackground({
  required Uint8List bytes,
  required int maxDim,
}) => compute(
  // A null-safe wrapper accepts the `(Uint8List, int)` record.
  (record) => computeIsolatedThumbnail(record.$1, record.$2),
  (bytes, maxDim),
);

/// What a loaded document preview is: an image thumbnail, a rendered PDF first
/// page (already downscaled), or the deterministic icon placeholder.
sealed class DocumentPreview {
  const DocumentPreview();
}

/// A decoded + downscaled image thumbnail (PNG bytes), ready for [Image.memory].
class DocumentPreviewImage extends DocumentPreview {
  const DocumentPreviewImage(this.bytes);

  /// Small PNG thumbnail bytes.
  final Uint8List bytes;
}

/// A rendered first page of a PDF, already sized to (at most) 512 px so the
/// detail panel can show it without a second decode. The embeddable PDF widget
/// is used only for the *interactive* detail panel; thumbnails for PDFs reuse
/// this rendered image.
class DocumentPreviewPdf extends DocumentPreview {
  const DocumentPreviewPdf(this.pdfThumbnail);

  /// The rendered first page (bytes + dimensions).
  final PdfThumbnail pdfThumbnail;
}

/// Fallback: an arbitrary document for which no visual preview could be
/// produced (text documents by design, images/PDFs on decode failure). The UI
/// renders a MIME/extension-derived glyph on a deterministic colored tile.
class DocumentPreviewFallback extends DocumentPreview {
  const DocumentPreviewFallback();
}

const DocumentPreviewFallback _fallback = DocumentPreviewFallback();

/// A PDF page rendered to image bytes plus its intrinsic dimensions (used in
/// place of the opaque `PdfPageImage` in detail + thumbnail rendering).
class PdfThumbnail {
  const PdfThumbnail({
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// Rendered first-page image bytes (JPEG).
  final Uint8List bytes;

  /// Rendered pixel width.
  final int width;

  /// Rendered pixel height.
  final int height;
}

/// The standard pdfx-backed PDF opener + first-page renderer.
///
/// Opens the document from bytes, renders page 1 at a bounded resolution
/// (512 px long edge), closes the page and document, and returns the page image
/// already downscaled by the renderer, so the detail panel can `Image.memory`
/// it directly without re-encoding or holding an open native handle.
Future<PdfPageImage> openPdfFirstPage(Uint8List bytes) async {
  final document = await PdfDocument.openData(bytes);
  try {
    final page = await document.getPage(1);
    try {
      final image = await page.render(
        // pdfx render() takes explicit pixel dimensions; we bound a long edge
        // so huge PDFs render a small preview without OOM.
        width: 512,
        height: 512,
        format: PdfPageImageFormat.jpeg,
        backgroundColor: '#ffffff',
        quality: 80,
      );
      if (image == null) {
        throw StateError('PDF page render returned no image');
      }
      return image;
    } finally {
      await page.close();
    }
  } finally {
    await document.close();
  }
}

/// Real pdfx support probe.
///
/// pdfx supports Android/iOS/macOS/web/Windows but **not** Linux, so PDF
/// previews degrade to the icon placeholder there. Wrapped so a platform probe
/// failure never escapes into the preview pipeline.
Future<bool> pdfxPlatformSupport() async {
  try {
    return await hasPdfSupport();
  } catch (_) {
    return false;
  }
}

/// A tiny LRU cache (not a `Map` subclass) for [DocumentPreview] values.
///
/// Keeps the most-recently-used entries up to [capacity]; evicts oldest on
/// overflow. Backed by an ordered list of keys plus a map so insertion order
/// doubles as recency order.
class DocumentPreviewCache {
  DocumentPreviewCache({this.capacity = 64})
    : assert(capacity > 0, 'capacity must be positive');

  /// Maximum number of document previews retained.
  final int capacity;

  final _entries = <String, DocumentPreview>{};
  final _order = <String>[];

  /// The settled preview for [documentId], or `null` when not cached.
  DocumentPreview? operator [](String documentId) => _entries[documentId];

  void _touch(String key) {
    _order.remove(key);
    _order.add(key);
  }

  /// Settle a preview for [documentId], evicting oldest entries past the cap.
  void put(String documentId, DocumentPreview preview) {
    if (!_entries.containsKey(documentId)) {
      _order.add(documentId);
    } else {
      _touch(documentId);
    }
    _entries[documentId] = preview;
    while (_order.length > capacity) {
      final oldest = _order.removeAt(0);
      _entries.remove(oldest);
    }
  }

  /// Whether [documentId] has a cached (settled) preview.
  bool contains(String documentId) => _entries.containsKey(documentId);

  /// Forget a document (e.g. after a rename/content edit invalidates it).
  void remove(String documentId) {
    _order.remove(documentId);
    _entries.remove(documentId);
  }

  /// Drop every entry.
  void clear() {
    _entries.clear();
    _order.clear();
  }
}

/// A promise-style cache entry: either a settled result or an in-flight future
/// so concurrent loads for the same id coalesce into a single read.
class _PendingEntry {
  _PendingEntry(this.id, this.future);

  final String id;
  final Future<DocumentPreview> future;
  DateTime lastUsed = DateTime.now();
}

/// Loads and caches document previews on behalf of the list and detail views.
///
/// Shared across the Documents browse list, search results, and the detail
/// panel so all three read the underlying blob at most once per document.
class DocumentPreviewLoader {
  DocumentPreviewLoader({
    required this.bytesSource,
    DocumentPreviewCache? cache,
    PdfOpener? pdfOpener,
    ImageThumbnailer? imageThumbnailer,
    PdfSupportChecker? pdfSupport,
  }) : cache = cache ?? sharedCache,
       pdfOpener = pdfOpener ?? openPdfFirstPage,
       imageThumbnailer =
           imageThumbnailer ?? computeIsolatedThumbnailInBackground,
       pdfSupport = pdfSupport ?? pdfxPlatformSupport;

  // Note: `computeIsolatedThumbnailInBackground` is a top-level function so it
  // can be referenced from the initializer list above (instance members cannot
  // be used before `super`/initializers).

  /// How raw bytes are fetched (production: `DocumentService.readBytes`).
  final ImageBytesSource bytesSource;

  /// The shared LRU cache; defaults to a process-wide instance so list and
  /// detail panels reuse loads (injectable for tests).
  final DocumentPreviewCache cache;

  /// Opens/renders a PDF first page from raw bytes.
  final PdfOpener pdfOpener;

  /// Downscales an image to a small PNG thumbnail.
  final ImageThumbnailer imageThumbnailer;

  /// Whether PDF rendering is supported on this platform.
  final PdfSupportChecker pdfSupport;

  /// The process-wide default cache shared by every [DocumentPreviewLoader]
  /// constructed without an explicit cache.
  static final DocumentPreviewCache sharedCache = DocumentPreviewCache();

  final _pending = <String, _PendingEntry>{};

  /// Classify a document's visual preview kind: `'image'`, `'pdf'`, or `null`
  /// (use the fallback tile).
  String? _previewKindOf(DocumentSummary document) {
    final mime = (document.mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return 'image';
    if (mime == 'application/pdf' ||
        mime == 'application/x-pdf' ||
        mime == 'application/acrobat') {
      return 'pdf';
    }
    return null;
  }

  /// Whether a document has a potential visual preview at all (an image or a
  /// PDF, i.e. something whose raw bytes could be shown).
  bool canPreview(DocumentSummary document) => _previewKindOf(document) != null;

  /// The preferred visual preview for a document.
  ///
  /// Cache-hit loads return the settled preview immediately; every other case
  /// returns a future the caller awaits, and the settled result (including
  /// [DocumentPreviewFallback] on failure) is cached so repeated list/detail
  /// rebuilds never re-read the blob store.
  Future<DocumentPreview> previewFor(DocumentSummary document) async {
    final kind = _previewKindOf(document);
    if (kind == null) return _fallback;
    final cached = cache[document.id];
    if (cached != null) return cached;
    // Coalesce concurrent loads for the same id into a single read.
    final pending = _pending[document.id];
    if (pending != null) {
      pending.lastUsed = DateTime.now();
      return pending.future;
    }
    final future = _load(document, kind);
    _pending[document.id] = _PendingEntry(document.id, future);
    future.whenComplete(() => _pending.remove(document.id));
    return future;
  }

  Future<DocumentPreview> _load(DocumentSummary document, String kind) async {
    DocumentPreview result;
    try {
      final raw = await bytesSource(document.id);
      if (raw.isEmpty) return _fallback;
      final bytes = _asBytes(raw);
      result = switch (kind) {
        'image' => await _loadImage(bytes),
        'pdf' => await _loadPdf(bytes),
        _ => _fallback,
      };
    } catch (_) {
      // Any read/decode/platform failure degrades to the icon placeholder;
      // previews are best-effort and must never brick the list/detail.
      result = _fallback;
    }
    cache.put(document.id, result);
    return result;
  }

  Future<DocumentPreview> _loadImage(Uint8List bytes) async {
    final thumb = await imageThumbnailer(bytes: bytes, maxDim: 512);
    if (thumb == null || thumb.isEmpty) return _fallback;
    return DocumentPreviewImage(thumb);
  }

  Future<DocumentPreview> _loadPdf(Uint8List bytes) async {
    if (!await pdfSupport()) return _fallback;
    final pageImage = await pdfOpener(bytes);
    final thumb = await _pdfThumbnailFrom(pageImage);
    if (thumb == null) return _fallback;
    return DocumentPreviewPdf(thumb);
  }

  /// Extract a bounded [PdfThumbnail] from a rendered pdfx page.
  Future<PdfThumbnail?> _pdfThumbnailFrom(PdfPageImage pageImage) async {
    final w = pageImage.width;
    final h = pageImage.height;
    if (w == null || h == null || w <= 0 || h <= 0) return null;
    final bytes = pageImage.bytes;
    if (bytes.isEmpty) return null;
    return PdfThumbnail(bytes: bytes, width: w, height: h);
  }

  /// Whether [document] should render the visual preview path in a given UI
  /// (i.e. a real image/PDF preview, not the fallback tile).
  bool shouldShowVisual(DocumentSummary document) {
    final cached = cache[document.id];
    return cached is DocumentPreviewImage || cached is DocumentPreviewPdf;
  }

  /// Drop the cached preview for [id] (e.g. after content/bytes change).
  void invalidate(String id) {
    cache.remove(id);
    _pending.remove(id);
  }
}
