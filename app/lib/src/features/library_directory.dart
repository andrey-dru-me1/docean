library;

import '../rust/api/library.dart' as library_bridge;
import '../rust/api/storage.dart' show DocumentRepository;
import 'repository.dart' show openSharedRepository;

class LibrarySyncSummary {
  final int added;
  final int removed;
  final int linked;
  final int failed;

  const LibrarySyncSummary({
    required this.added,
    required this.removed,
    required this.linked,
    required this.failed,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LibrarySyncSummary &&
          runtimeType == other.runtimeType &&
          added == other.added &&
          removed == other.removed &&
          linked == other.linked &&
          failed == other.failed;

  @override
  int get hashCode => Object.hash(added, removed, linked, failed);
}

abstract interface class LibraryDirectoryService {
  Future<String?> libraryDirectory();
  Future<void> setLibraryDirectory(String? path);
  Future<LibrarySyncSummary> syncLibrary();
}

/// The production implementation backed by the Rust bridge.
///
/// Shares the process-wide cached [`DocumentRepository`] (via
/// [openSharedRepository]) with ingestion, browse, and search, so a sync here
/// operates on the *same* underlying store the rest of the app uses.
class BridgeLibraryDirectoryService implements LibraryDirectoryService {
  const BridgeLibraryDirectoryService({this._repositoryRoot});

  final Future<String> Function()? _repositoryRoot;

  Future<DocumentRepository> _repo() =>
      openSharedRepository(root: _repositoryRoot);

  @override
  Future<String?> libraryDirectory() async {
    final repo = await _repo();
    return library_bridge.libraryGetDirectory(repo: repo);
  }

  @override
  Future<void> setLibraryDirectory(String? path) async {
    final repo = await _repo();
    library_bridge.librarySetDirectory(repo: repo, dir: path);
  }

  @override
  Future<LibrarySyncSummary> syncLibrary() async {
    final repo = await _repo();
    final dto = library_bridge.librarySync(repo: repo);
    return LibrarySyncSummary(
      added: dto.added.length,
      removed: dto.removed.length,
      linked: dto.linked.length,
      failed: dto.failed.length,
    );
  }
}

class InMemoryLibraryDirectoryService implements LibraryDirectoryService {
  String? _dir;

  @override
  Future<String?> libraryDirectory() async => _dir;

  @override
  Future<void> setLibraryDirectory(String? path) async => _dir = path;

  @override
  Future<LibrarySyncSummary> syncLibrary() async =>
      const LibrarySyncSummary(added: 0, removed: 0, linked: 0, failed: 0);
}
