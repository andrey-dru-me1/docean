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

import 'dart:io' show Platform;
import 'dart:typed_data';

import 'package:archive/archive.dart' show ZipDecoder;
import 'package:collection/collection.dart' show IterableExtension;
import 'package:flutter/foundation.dart' show compute, kIsWeb;
import 'package:image/image.dart' as img;
import 'package:pdfx/pdfx.dart'
    show PdfDocument, PdfPageImage, PdfPageImageFormat, hasPdfSupport;
import 'package:xml/xml.dart'
    show XmlDocument, XmlFindExtension, XmlStringExtension;

import 'docx_rasterizer.dart' show quickLookDocxRasterizer;
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

/// Attempts to render the first page of a docx document to a raster image
/// (PNG/JPEG bytes). Injectable so widget tests never invoke the native
/// platform channels (QuickLook / Shell / LibreOffice).
typedef DocxRasterizer = Future<Uint8List?> Function(Uint8List bytes);

/// Extracts the first page of text from a docx (OOXML archive). Returns
/// paragraph text capped at ~2000 chars, or `null` when the archive is
/// corrupt or contains no parseable text. Injectable so tests can observe
/// the extraction pipeline without invoking `compute`.
typedef DocxTextExtractor = Future<String?> Function(Uint8List bytes);

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

/// The first page of text extracted from an OOXML document (docx/docm/dotx).
///
/// When no native rasterizer is available (Android, missing LibreOffice/QuickLook
/// on desktop), the loader extracts paragraph text from `word/document.xml`
/// and the UI renders it on a white page-styled tile — a lightweight fallback
/// that still communicates "this is a document" rather than the generic glyph.
class DocumentPreviewTextPage extends DocumentPreview {
  const DocumentPreviewTextPage(this.text);

  /// The first ~2000 characters of paragraph text from the document body.
  final String text;
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

/// The production docx rasterizer for the current platform.
///
/// * macOS → QuickLook via [`MethodChannel`] (see [quickLookDocxRasterizer]).
/// * Other platforms → no-op; the text-page fallback handles preview.
///
/// Injected by the [`DocumentPreviewLoader`] constructor; overridable in tests.
DocxRasterizer get platformDocxRasterizer {
  if (!kIsWeb && Platform.isMacOS) return quickLookDocxRasterizer;
  // Windows/Linux Shell thumbnail could be added here in the future.
  return _noopDocxRasterizer;
}

/// No-op rasterizer — always returns `null`, used on platforms without a
/// native docx renderer and as the test double.
Future<Uint8List?> _noopDocxRasterizer(Uint8List bytes) async => null;

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

/// Whether the [document] is an OOXML Word document (docx/docm/dotx/dotm)
/// whose MIME type or original file extension signals a previewable Word file.
bool _isDocxLike(DocumentSummary document) {
  final mime = (document.mimeType ?? '').toLowerCase();
  // MIME types produced by the Rust ingest pipeline.
  if (mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.document' ||
      mime == 'application/vnd.ms-word.document.macroenabled.12' ||
      mime ==
          'application/vnd.openxmlformats-officedocument.wordprocessingml.template' ||
      mime == 'application/vnd.ms-word.template.macroenabled.12') {
    return true;
  }
  // Fallback: check the original file extension when MIME is missing or
  // non-standard (e.g. the generic 'application/octet-stream' heuristic).
  final name = (document.originalName ?? '').toLowerCase();
  return name.endsWith('.docx') ||
      name.endsWith('.docm') ||
      name.endsWith('.dotx') ||
      name.endsWith('.dotm');
}

/// Maximum characters of paragraph text extracted from a docx for preview.
const int _kDocxTextPreviewLimit = 2000;

/// The OOXML `w:t` namespace URI used to match paragraph and text-run
/// elements regardless of prefix (typically `w:` but could be anything).
const String _wNamespaceUri =
    'http://schemas.openxmlformats.org/wordprocessingml/2006/main';

/// Pure docx text extraction meant to run on a background isolate via
/// [compute]. Unzips the OOXML archive, parses `word/document.xml`, walks
/// `<w:p>` paragraphs and `<w:t>` text runs, and returns the first
/// [_kDocxTextPreviewLimit] characters of body text. Returns `null` on
/// archive or parse failure so the caller degrades to the fallback tile.
String? computeIsolatedDocxText(Uint8List bytes) {
  try {
    final archive = ZipDecoder().decodeBytes(bytes, verify: false);
    final docEntry = archive.firstWhereOrNull(
      (e) => e.name == 'word/document.xml' || e.name.endsWith('/document.xml'),
    );
    if (docEntry == null) return null;
    final content = docEntry.content;
    final xmlStr = String.fromCharCodes(content);
    final doc = XmlDocument.parse(xmlStr);
    final paragraphs = doc.findAllElements('p', namespaceUri: _wNamespaceUri);
    final buf = StringBuffer();
    for (final p in paragraphs) {
      final runs = p.findAllElements('t', namespaceUri: _wNamespaceUri);
      for (final t in runs) {
        buf.write(t.innerText);
      }
      if (buf.length >= _kDocxTextPreviewLimit) break;
      // Separate paragraphs with a newline so the preview preserves structure.
      buf.writeln();
    }
    final text = buf.toString().trimRight();
    if (text.isEmpty) return null;
    // Enforce the character cap.
    if (text.length <= _kDocxTextPreviewLimit) return text;
    return '${text.substring(0, _kDocxTextPreviewLimit)}…';
  } catch (_) {
    // Corrupt archive or malformed XML — degrade gracefully.
    return null;
  }
}

/// Production docx text extractor: run the pure [computeIsolatedDocxText] on a
/// background isolate via `compute`.
Future<String?> computeIsolatedDocxTextInBackground(Uint8List bytes) =>
    compute(computeIsolatedDocxText, bytes);

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
    DocxRasterizer? docxRasterizer,
    DocxTextExtractor? docxTextExtractor,
  }) : cache = cache ?? sharedCache,
       pdfOpener = pdfOpener ?? openPdfFirstPage,
       imageThumbnailer =
           imageThumbnailer ?? computeIsolatedThumbnailInBackground,
       pdfSupport = pdfSupport ?? pdfxPlatformSupport,
       docxRasterizer = docxRasterizer ?? platformDocxRasterizer,
       docxTextExtractor =
           docxTextExtractor ?? computeIsolatedDocxTextInBackground;

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

  /// Renders the first page of a docx to a raster image, when a native
  /// rasterizer exists on this platform. Defaults to the module-level
  /// [platformDocxRasterizer]; injectable so widget tests can force the
  /// text-page (or image) path deterministically.
  final DocxRasterizer docxRasterizer;

  /// Extracts the first page of text from a docx. Defaults to the isolate
  /// [computeIsolatedDocxTextInBackground]; injectable in tests.
  final DocxTextExtractor docxTextExtractor;

  /// The process-wide default cache shared by every [DocumentPreviewLoader]
  /// constructed without an explicit cache.
  static final DocumentPreviewCache sharedCache = DocumentPreviewCache();

  final _pending = <String, _PendingEntry>{};

  /// Classify a document's visual preview kind: `'image'`, `'pdf'`, `'docx'`,
  /// or `null` (use the fallback tile).
  String? _previewKindOf(DocumentSummary document) {
    final mime = (document.mimeType ?? '').toLowerCase();
    if (mime.startsWith('image/')) return 'image';
    if (mime == 'application/pdf' ||
        mime == 'application/x-pdf' ||
        mime == 'application/acrobat') {
      return 'pdf';
    }
    if (_isDocxLike(document)) return 'docx';
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
        'docx' => await _loadDocx(bytes),
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
  /// (i.e. a real image/PDF/text-page preview, not the fallback tile).
  bool shouldShowVisual(DocumentSummary document) {
    final cached = cache[document.id];
    return cached is DocumentPreviewImage ||
        cached is DocumentPreviewPdf ||
        cached is DocumentPreviewTextPage;
  }

  /// Drop the cached preview for [id] (e.g. after content/bytes change).
  void invalidate(String id) {
    cache.remove(id);
    _pending.remove(id);
  }

  /// Load a docx preview via the tiered pipeline:
  /// 1. Attempt the platform rasterizer (QuickLook / Shell / LibreOffice) →
  ///    image preview (best fidelity).
  /// 2. On rasterizer failure / unavailability, fall back to the pure-Dart
  ///    text-page extraction from `word/document.xml` → text page preview.
  /// 3. If text extraction yields nothing, degrade to the generic fallback.
  Future<DocumentPreview> _loadDocx(Uint8List bytes) async {
    // Tier 1: native rasterizer (platform-specific, injectable).
    final rasterized = await docxRasterizer(bytes);
    if (rasterized != null && rasterized.isNotEmpty) {
      return DocumentPreviewImage(rasterized);
    }
    // Tier 2: pure-Dart text extraction from the OOXML ZIP.
    final text = await docxTextExtractor(bytes);
    if (text != null && text.trim().isNotEmpty) {
      return DocumentPreviewTextPage(text.trim());
    }
    // Tier 3: no preview at all.
    return _fallback;
  }
}
