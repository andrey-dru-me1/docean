/// A thin, typed facade over the generated ingestion bindings, mirroring how
/// [`SearchService`](search_service.dart) wraps the search bridge surface.
///
/// The facade streams [`IngestEvent`]s back to the UI. It is deliberately an
/// interface so widget tests can inject a fake implementation without loading
/// the native library.
library;

import '../rust/api/ingest.dart' as bridge;
import '../rust/api/ingest.dart' show IngestEvent;
import '../rust/api/storage.dart' show DocumentRepository;
import 'repository.dart' show defaultRepositoryRoot, openSharedRepository;

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
    : _repositoryRoot = repositoryRoot ?? defaultRepositoryRoot;

  final Future<String> Function() _repositoryRoot;

  /// Resolve the (shared, cached) repository handle for the configured root.
  Future<DocumentRepository> _repository() =>
      openSharedRepository(root: _repositoryRoot);

  @override
  Stream<IngestEvent> ingestFiles(List<String> paths) async* {
    final repo = await _repository();
    yield* bridge.ingestFiles(repo: repo, paths: paths, skipExisting: true);
  }
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
