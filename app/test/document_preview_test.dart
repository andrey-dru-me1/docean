import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:docer/src/features/document_preview.dart'
    show
        DocumentPreviewCache,
        DocumentPreviewFallback,
        DocumentPreviewImage,
        DocumentPreviewLoader;
import 'package:docer/src/features/document_service.dart'
    show FakeDocumentService;
import 'package:docer/src/ui/document_preview_view.dart'
    show DocumentPlaceholder, DocumentPreviewPanel, DocumentThumbnail;
import 'package:docer/src/ui/document_view.dart'
    show DocumentDetailView, DocumentSummary;

Widget _wrap(Widget child) => MaterialApp(
  theme: _panelTheme(),
  home: Scaffold(body: child),
);

/// A large-frame theme so the panel's [Card] isn't squeezed by preview text
/// (Material 3 Card heights behave correctly even when unconstrained).
ThemeData _panelTheme() => ThemeData(
  useMaterial3: true,
  colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
);

/// A tiny valid PNG (10×10 solid teal) encoded via package:image.
Uint8List _pngBytes() =>
    Uint8List.fromList(img.encodePng(img.Image(width: 10, height: 10)));

DocumentSummary _doc(
  String id, {
  String? mimeType,
  String originalName = '',
  String title = 'Doc',
}) => DocumentSummary(
  id: id,
  title: title,
  mimeType: mimeType,
  originalName: originalName.isEmpty ? null : originalName,
);

/// A loader whose bytes source reads from a [FakeDocumentService] and whose
/// image thumbnailer runs synchronously (isolate-free) so widget tests resolve
/// under FakeAsync. PDF support is forced off so PDF previews deterministically
/// degrade to the icon placeholder without touching the native platform
/// channel.
DocumentPreviewLoader _loaderFor(FakeDocumentService service) =>
    DocumentPreviewLoader(
      bytesSource: (id) => service.readBytes(id),
      imageThumbnailer: ({required bytes, required maxDim}) async =>
          _thumbnailer(bytes, maxDim),
      pdfSupport: () async => false,
    );

Future<Uint8List?> _thumbnailer(Uint8List bytes, int maxDim) async {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  final scale =
      (maxDim /
              (decoded.width > decoded.height ? decoded.width : decoded.height))
          .clamp(0.0, 1.0);
  final resized = img.copyResize(
    decoded,
    width: (decoded.width * scale).round(),
    height: (decoded.height * scale).round(),
  );
  return Uint8List.fromList(img.encodePng(resized));
}

void main() {
  group('DocumentPreviewLoader', () {
    test('image bytes become a PNG image preview', () async {
      final service = FakeDocumentService(
        documents: [_doc('img-1', mimeType: 'image/png')],
        bytesByDocumentId: {'img-1': _pngBytes()},
      );
      final loader = _loaderFor(service);

      final preview = await loader.previewFor(
        _doc('img-1', mimeType: 'image/png'),
      );

      expect(preview, isA<DocumentPreviewImage>());
      final imagePreview = preview as DocumentPreviewImage;
      expect(imagePreview.bytes, isNotEmpty);
      // The output is a decodable PNG (downscaled).
      expect(img.decodeImage(imagePreview.bytes), isNotNull);
      // Cached for subsequent calls (same instance).
      expect(loader.cache['img-1'], same(preview));
    });

    test(
      'a non-image/non-PDF doc always yields the fallback placeholder',
      () async {
        final service = FakeDocumentService(
          documents: [_doc('txt-1', mimeType: 'text/plain')],
          bytesByDocumentId: {'txt-1': _pngBytes()},
        );
        final loader = _loaderFor(service);

        final preview = await loader.previewFor(
          _doc('txt-1', mimeType: 'text/plain'),
        );

        expect(preview, isA<DocumentPreviewFallback>());
        expect(
          loader.canPreview(_doc('txt-1', mimeType: 'text/plain')),
          isFalse,
        );
      },
    );

    test('a PDF on an unsupported platform degrades to the fallback', () async {
      final service = FakeDocumentService(
        documents: [_doc('pdf-1', mimeType: 'application/pdf')],
        bytesByDocumentId: {'pdf-1': _pngBytes()},
      );
      final loader = _loaderFor(service);

      final preview = await loader.previewFor(
        _doc('pdf-1', mimeType: 'application/pdf'),
      );

      expect(preview, isA<DocumentPreviewFallback>());
    });

    test(
      'a failed bytes read never throws; it degrades to the fallback',
      () async {
        final loader = DocumentPreviewLoader(
          bytesSource: (id) async => throw StateError('blob missing'),
          cache: DocumentPreviewCache(),
          imageThumbnailer: ({required bytes, required maxDim}) async => null,
          pdfSupport: () async => false,
        );

        final preview = await loader.previewFor(
          _doc('missing-1', mimeType: 'image/png'),
        );

        expect(preview, isA<DocumentPreviewFallback>());
        // The failed result is cached so repeated reads don't re-throw.
        expect(loader.cache['missing-1'], isA<DocumentPreviewFallback>());
      },
    );

    test('LRU cache evicts the least-recently-used entry past capacity', () {
      final cache = DocumentPreviewCache(capacity: 2);
      cache.put('a', const DocumentPreviewFallback());
      cache.put('b', const DocumentPreviewFallback());
      cache.put('c', const DocumentPreviewFallback());

      expect(cache.contains('a'), isFalse);
      expect(cache.contains('b'), isTrue);
      expect(cache.contains('c'), isTrue);
    });
  });

  group('DocumentThumbnail', () {
    testWidgets('renders an image thumbnail for an image document', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [_doc('img-1', mimeType: 'image/png', title: 'Photo')],
        bytesByDocumentId: {'img-1': _pngBytes()},
      );
      final loader = _loaderFor(service);

      await tester.pumpWidget(
        _wrap(
          DocumentThumbnail(
            document: _doc('img-1', mimeType: 'image/png', title: 'Photo'),
            loader: loader,
            size: 64,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // The thumbnail is an Ink feature painting the memory bytes (so
      // InkWell splashes paint over it when inside a Card).
      expect(find.byType(Ink), findsOneWidget);
      // No fallback placeholder tile with the insert-drive glyph.
      expect(find.byType(DocumentPlaceholder), findsNothing);
    });

    testWidgets('renders the fallback placeholder for text documents', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [_doc('txt-1', mimeType: 'text/plain', title: 'Notes')],
        bytesByDocumentId: {'txt-1': _pngBytes()},
      );
      final loader = _loaderFor(service);

      await tester.pumpWidget(
        _wrap(
          DocumentThumbnail(
            document: _doc('txt-1', mimeType: 'text/plain', title: 'Notes'),
            loader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(DocumentPlaceholder), findsOneWidget);
    });

    testWidgets(
      'a corrupt image degrades to the placeholder without crashing',
      (tester) async {
        final service = FakeDocumentService(
          documents: [_doc('bad-1', mimeType: 'image/png', title: 'Bad')],
          bytesByDocumentId: {
            'bad-1': Uint8List.fromList([1, 2, 3]),
          },
        );
        final loader = _loaderFor(service);

        await tester.pumpWidget(
          _wrap(
            DocumentThumbnail(
              document: _doc('bad-1', mimeType: 'image/png', title: 'Bad'),
              loader: loader,
            ),
          ),
        );
        await tester.pumpAndSettle();

        expect(find.byType(DocumentPlaceholder), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  });

  group('DocumentPreviewPanel', () {
    testWidgets('shows a preview panel for an image document', (tester) async {
      final service = FakeDocumentService(
        documents: [_doc('img-2', mimeType: 'image/jpeg', title: 'JPEG')],
        bytesByDocumentId: {'img-2': _pngBytes()},
      );
      final loader = _loaderFor(service);

      await tester.pumpWidget(
        _wrap(
          DocumentPreviewPanel(
            document: _doc('img-2', mimeType: 'image/jpeg', title: 'JPEG'),
            loader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.byType(Image), findsOneWidget);
      expect(find.byType(DocumentPlaceholder), findsNothing);

      // The preview stage fills the preview area (width/height-bound) with the
      // original white card — no A4-aspect frame nested around the image.
      expect(find.byType(AspectRatio), findsNothing);
      expect(
        find.ancestor(of: find.byType(Image), matching: find.byType(Card)),
        findsOneWidget,
      );
    });

    testWidgets('PDF preview degrades to nothing (keeps content viewer)', (
      tester,
    ) async {
      final service = FakeDocumentService(
        documents: [_doc('pdf-9', mimeType: 'application/pdf', title: 'PDF')],
        bytesByDocumentId: {'pdf-9': _pngBytes()},
      );
      final loader = _loaderFor(service);

      await tester.pumpWidget(
        _wrap(
          DocumentPreviewPanel(
            document: _doc('pdf-9', mimeType: 'application/pdf', title: 'PDF'),
            loader: loader,
          ),
        ),
      );
      await tester.pumpAndSettle();

      // On an unsupported platform the panel renders nothing (keeps the text
      // viewer below) rather than a broken PDF frame.
      expect(find.byType(Ink), findsNothing);
      expect(find.byType(DocumentPlaceholder), findsNothing);
    });
  });

  group('loader wiring with DocumentDetailView', () {
    testWidgets('detail view inserts an image preview panel for images', (
      tester,
    ) async {
      final doc = _doc('img-5', mimeType: 'image/png', title: 'Image doc');
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'img-5': 'Alt text for the image.'},
        bytesByDocumentId: {'img-5': _pngBytes()},
      );

      await tester.pumpWidget(
        _wrap(
          DocumentDetailView(
            document: doc,
            documentService: service,
            previewLoader: _loaderFor(service),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Preview section + image rendered.
      expect(find.text('Preview'), findsOneWidget);
      expect(find.byType(Image), findsOneWidget);
    });

    testWidgets('detail view keeps text viewer for text documents', (
      tester,
    ) async {
      final doc = _doc('txt-5', mimeType: 'text/plain', title: 'Text doc');
      final service = FakeDocumentService(
        documents: [doc],
        contentByDocumentId: {'txt-5': 'A plain text body.'},
        bytesByDocumentId: {
          'txt-5': Uint8List.fromList([1, 2, 3]),
        },
      );

      await tester.pumpWidget(
        _wrap(DocumentDetailView(document: doc, documentService: service)),
      );
      await tester.pumpAndSettle();

      expect(find.text('Preview'), findsNothing);
      expect(find.textContaining('A plain text body'), findsOneWidget);
      expect(find.byType(Ink), findsNothing);
    });
  });
}
