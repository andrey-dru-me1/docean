/// A thin, typed facade over the generated storage + search bindings that
/// exposes the persisted document library to the UI.
///
/// Mirrors the service-injection/testability pattern of
/// [`SearchService`](search_service.dart) and
/// [`IngestService`](ingest_service.dart): the interface is what the UI depends
/// on, the bridge-backed implementation is the production default, and fakes
/// (e.g. [FakeDocumentService]) are used in widget tests without loading the
/// native library.
library;

import '../rust/api/search.dart' as search_bridge;
import '../rust/api/storage.dart' show DocumentRepository;
import '../rust/domain.dart' show Document, NodeKind;
import '../rust/storage.dart' show DocumentQuery;
import '../ui/document_view.dart' show DocumentSummary;
import 'repository.dart' show openSharedRepository;

/// The document-library service contract. Implement with the Rust bridge,
/// fakes in tests.
abstract interface class DocumentService {
  /// List every persisted document (metadata from `repo.query`), newest first,
  /// with tags and hierarchy paths resolved from the repository.
  Future<List<DocumentSummary>> listDocuments();

  /// Fresh metadata for a single document (used by the detail view to reflect
  /// tag edits and to resolve the original file name / MIME type).
  Future<DocumentSummary> getDocument(String id);

  /// The extracted plain-text content for a document, or `null` when the
  /// document has none yet (e.g. images without OCR).
  Future<String?> getContent(String id);

  /// The document's raw bytes, read from the content-addressed blob store.
  Future<List<int>> readBytes(String id);

  /// Replace the document's tag set, persisting the assignment in the
  /// repository and mirroring it into the in-memory search metadata so results
  /// can be filtered by the new tags immediately.
  Future<void> setTags(String id, List<String> tags);

  /// All tag names known to the repository (`repo.listTags`).
  Future<List<String>> listTags();

  /// All hierarchy paths known to the repository (`repo.listPaths`).
  Future<List<String>> listPaths();

  /// Rebuild the in-memory search index from the persisted repository.
  ///
  /// Called once at app startup so documents stored in previous sessions are
  /// searchable even though the ephemeral in-memory engine starts empty.
  Future<void> reindex();
}

/// The default implementation backed by the Rust bridge.
///
/// Shares the process-wide cached [`DocumentRepository`] with the ingestion
/// service, so files stored through [`BridgeIngestService`] are immediately
/// visible here and vice versa.
class BridgeDocumentService implements DocumentService {
  const BridgeDocumentService({this._repositoryRoot});

  final Future<String> Function()? _repositoryRoot;

  Future<DocumentRepository> _repo() =>
      openSharedRepository(root: _repositoryRoot);

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    final repo = await _repo();
    final docs = await repo.query(
      query: DocumentQuery(
        kind: NodeKind.document,
        tags: const [],
        limit: 1000,
      ),
    );
    final summaries = <DocumentSummary>[];
    for (final doc in docs) {
      final paths = await _pathsOf(repo, doc);
      summaries.add(_summaryOf(doc, paths));
    }
    return summaries;
  }

  Future<List<String>> _pathsOf(DocumentRepository repo, Document doc) async {
    try {
      final paths = await repo.pathsOf(documentId: doc.id);
      return [for (final p in paths) p.path];
    } catch (_) {
      return const [];
    }
  }

  /// Fresh metadata for a single document, resolving paths from the repository.
  @override
  Future<DocumentSummary> getDocument(String id) async {
    final repo = await _repo();
    final doc = await repo.get_(id: id);
    final paths = await _pathsOf(repo, doc);
    return _summaryOf(doc, paths);
  }

  /// The extracted text for a document, if any has been persisted.
  @override
  Future<String?> getContent(String id) async {
    final repo = await _repo();
    final content = await repo.getContent(documentId: id);
    return content?.text;
  }

  /// The raw bytes of a document from the content-addressed blob store.
  @override
  Future<List<int>> readBytes(String id) async {
    final repo = await _repo();
    return await repo.readBytes(id: id);
  }

  /// Persist a document's tag set and mirror it into the search metadata.
  @override
  Future<void> setTags(String id, List<String> tags) async {
    final repo = await _repo();
    await repo.setTags(documentId: id, tags: tags);
    try {
      final doc = await repo.get_(id: id);
      final paths = await _pathsOf(repo, doc);
      search_bridge.searchSetMetadata(documentId: id, tags: tags, paths: paths);
    } catch (_) {
      // If the search metadata is unavailable the tags are still persisted in
      // the repository; search filtering simply falls back to repository-source.
    }
  }

  DocumentSummary _summaryOf(Document doc, List<String> paths) {
    return DocumentSummary(
      id: doc.id,
      title: doc.title,
      tags: doc.tags,
      paths: paths,
      mimeType: doc.mimeType,
      originalName: doc.extra['original_name'],
    );
  }

  @override
  Future<List<String>> listTags() async {
    final repo = await _repo();
    final tags = await repo.listTags();
    return [for (final t in tags) t.name];
  }

  @override
  Future<List<String>> listPaths() async {
    final repo = await _repo();
    final paths = await repo.listPaths();
    return [for (final p in paths) p.path];
  }

  @override
  Future<void> reindex() async {
    final repo = await _repo();
    search_bridge.searchReindexFromRepository(repo: repo);
  }
}

/// A test double backed by in-memory data, used by widget tests.
class FakeDocumentService implements DocumentService {
  FakeDocumentService({
    List<DocumentSummary> documents = const [],
    List<String> tags = const [],
    List<String> paths = const [],
    Map<String, String> contentByDocumentId = const {},
    Map<String, List<int>> bytesByDocumentId = const {},
  }) : documents = List.of(documents),
       tags = List.of(tags),
       paths = List.of(paths),
       contentByDocumentId = Map.of(contentByDocumentId),
       bytesByDocumentId = {
         for (final e in bytesByDocumentId.entries) e.key: List.of(e.value),
       };

  final List<DocumentSummary> documents;
  final List<String> tags;
  final List<String> paths;

  /// Extracted text keyed by document id (unit-level stand-in for repo content).
  final Map<String, String> contentByDocumentId;

  /// Raw bytes keyed by document id (unit-level stand-in for the blob store).
  final Map<String, List<int>> bytesByDocumentId;

  /// How many times [reindex] has been requested (startup wiring assertion).
  int reindexCount = 0;

  /// How many times [listDocuments] has been called (refresh assertion).
  int listCount = 0;

  /// How many times [setTags] has been called (tag-edit assertion).
  int setTagsCount = 0;

  /// The most recent tags passed to [setTags] (tag-edit assertion).
  List<String>? lastSetTags;

  DocumentSummary _byId(String id) => documents.firstWhere(
    (d) => d.id == id,
    orElse: () => throw StateError('document $id not found'),
  );

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    listCount++;
    return List.of(documents);
  }

  @override
  Future<DocumentSummary> getDocument(String id) async => _byId(id);

  @override
  Future<String?> getContent(String id) async => contentByDocumentId[id];

  @override
  Future<List<int>> readBytes(String id) async =>
      List.of(bytesByDocumentId[id] ?? const []);

  @override
  Future<void> setTags(String id, List<String> nextTags) async {
    setTagsCount++;
    lastSetTags = List.of(nextTags);
    final index = documents.indexWhere((d) => d.id == id);
    if (index < 0) throw StateError('document $id not found');
    final doc = documents[index];
    documents[index] = DocumentSummary(
      id: doc.id,
      title: doc.title,
      snippet: doc.snippet,
      tags: List.of(nextTags),
      paths: doc.paths,
      mimeType: doc.mimeType,
      originalName: doc.originalName,
    );
  }

  @override
  Future<List<String>> listTags() async => List.of(tags);

  @override
  Future<List<String>> listPaths() async => List.of(paths);

  @override
  Future<void> reindex() async {
    reindexCount++;
  }
}
