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
      summaries.add(
        DocumentSummary(
          id: doc.id,
          title: doc.title,
          tags: doc.tags,
          paths: paths,
        ),
      );
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
  }) : documents = List.of(documents),
       tags = List.of(tags),
       paths = List.of(paths);

  final List<DocumentSummary> documents;
  final List<String> tags;
  final List<String> paths;

  /// How many times [reindex] has been requested (startup wiring assertion).
  int reindexCount = 0;

  /// How many times [listDocuments] has been called (refresh assertion).
  int listCount = 0;

  @override
  Future<List<DocumentSummary>> listDocuments() async {
    listCount++;
    return List.of(documents);
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
