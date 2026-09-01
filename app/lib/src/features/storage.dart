import 'dart:typed_data';

import 'domain.dart';

/// Errors thrown by storage operations (mirrors `core::storage::StorageError`).
sealed class StorageError implements Exception {
  const StorageError();
}

class DocumentNotFound extends StorageError {
  const DocumentNotFound(this.id);

  final String id;

  @override
  String toString() => 'DocumentNotFound($id)';
}

class StorageClosed extends StorageError {
  const StorageClosed();

  @override
  String toString() => 'StorageClosed';
}

/// A predicate for listing documents (mirrors `core::storage::DocumentQuery`).
class DocumentQuery {
  const DocumentQuery({
    this.parent,
    this.tags = const [],
    this.kind,
    this.limit,
    this.offset,
  });

  final String? parent;
  final List<String> tags;
  final NodeKind? kind;
  final int? limit;
  final int? offset;
}

/// Local document store interface (mirrors `core::storage::DocumentStore`).
///
/// Backed by the Rust core once implemented; failures throw [StorageError].
abstract interface class DocumentStore {
  Future<void> put(Document doc, Uint8List bytes);
  Future<Document> get(String id);
  Future<Uint8List> readBytes(String id);
  Future<void> delete(String id);
  Future<List<Document>> query(DocumentQuery query);

  Future<void> link(HierarchyLink link);
  Future<List<String>> children(String parent);

  Future<void> putTag(Tag tag);
  Future<List<Tag>> listTags();
}
