/// Shared, lazily-opened [`DocumentRepository`] handle.
///
/// The Rust core holds the SQLite repository as a process-wide singleton (the
/// store is wrapped in `Arc<Mutex<_>>`); the Dart side mirrors that by caching a
/// single repository handle here so the ingestion, document-browse, and
/// search-reindex surfaces all operate on the *same* underlying store.
library;

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../rust/api/storage.dart' show DocumentRepository, openRepository;

/// Resolve the on-disk repository root: `<app-documents>/docer`.
///
/// Injectable for tests; the production default is the platform's
/// application-documents directory under a `docer` subfolder.
Future<String> defaultRepositoryRoot() async {
  final base = await getApplicationDocumentsDirectory();
  return p.join(base.path, 'docer');
}

DocumentRepository? _cached;
String? _cachedRoot;

/// Open (or reuse) the process-wide repository rooted at `root`.
///
/// `root` defaults to [defaultRepositoryRoot]; it is injectable so tests can
/// point at a temp directory without loading a real app container.
Future<DocumentRepository> openSharedRepository({
  Future<String> Function()? root,
}) async {
  final resolve = root ?? defaultRepositoryRoot;
  final resolved = await resolve();
  final cached = _cached;
  if (cached != null && _cachedRoot == resolved) return cached;
  final repo = await openRepository(root: resolved);
  _cached = repo;
  _cachedRoot = resolved;
  return repo;
}
