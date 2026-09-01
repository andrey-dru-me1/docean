/// A thin, typed facade over the generated ingestion bindings, mirroring how
/// [`SearchService`](search_service.dart) wraps the search bridge surface.
///
/// The facade owns the on-disk [`DocumentRepository`] (opened lazily on first
/// use) and streams [`IngestEvent`]s back to the UI. It is deliberately an
/// interface so widget tests can inject a fake implementation without loading
/// the native library.
library;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../rust/api/ingest.dart' as bridge;
import '../rust/api/ingest.dart' show IngestEvent;
import '../rust/api/storage.dart' show DocumentRepository, openRepository;

export '../rust/api/ingest.dart' show IngestEvent;

/// The ingestion service contract. Implement with the Rust bridge, fakes in
/// tests.
abstract interface class IngestService {
  /// Ingest a batch of files, streaming one [`IngestEvent`] per file as it
  /// moves through `processing` → `extracting` → `completed`/`failed`.
  Stream<IngestEvent> ingestFiles(List<String> paths);
}

/// The default implementation backed by the Rust bridge.
///
/// The repository handle is opened lazily and cached, so repeated ingestion
/// batches share the same on-disk store. The root directory is resolved via
/// [repositoryRoot] (injectable for tests); the production default is the
/// platform's application-documents directory under a `docer` subfolder.
class BridgeIngestService implements IngestService {
  const BridgeIngestService({Future<String> Function()? repositoryRoot})
    : _repositoryRoot = repositoryRoot ?? _defaultRepositoryRoot;

  final Future<String> Function() _repositoryRoot;

  // The repository is a process-wide singleton (mirrors the Rust core's
  // `OnceLock`-held store), cached here so repeated batches share one handle.
  static DocumentRepository? _cachedRepo;
  static String? _cachedRoot;

  /// Resolve the repository root on disk (lazily, once).
  Future<DocumentRepository> _repository() async {
    final root = await _repositoryRoot();
    final cached = _cachedRepo;
    if (cached != null && _cachedRoot == root) return cached;
    final repo = await openRepository(root: root);
    _cachedRepo = repo;
    _cachedRoot = root;
    return repo;
  }

  @override
  Stream<IngestEvent> ingestFiles(List<String> paths) async* {
    final repo = await _repository();
    yield* bridge.ingestFiles(repo: repo, paths: paths, skipExisting: false);
  }
}

/// Default repository root: `<app-documents>/docer`.
Future<String> _defaultRepositoryRoot() async {
  final base = await getApplicationDocumentsDirectory();
  return p.join(base.path, 'docer');
}

/// A test double that streams a fixed sequence of events without the bridge.
///
/// Provided as a convenience for widget tests; tests may also implement
/// [IngestService] directly.
class FakeIngestService implements IngestService {
  FakeIngestService(this.events);

  final List<IngestEvent> events;

  @override
  Stream<IngestEvent> ingestFiles(List<String> paths) async* {
    for (final e in events) {
      yield e;
    }
  }
}
