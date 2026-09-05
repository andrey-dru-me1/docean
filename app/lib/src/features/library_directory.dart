library;

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
