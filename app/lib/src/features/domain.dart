/// Shared domain model, mirroring `core::domain` on the Dart side.
///
/// These types are the common language used across every feature module.
library;

/// Whether a hierarchy node is a leaf document or a folder/collection.
enum NodeKind { document, folder }

/// A document's indexed metadata record (raw bytes live in the blob store).
class Document {
  const Document({
    required this.id,
    required this.kind,
    required this.title,
    required this.mimeType,
    required this.sizeBytes,
    required this.checksumSha256,
    required this.tags,
    required this.createdAtMs,
    required this.updatedAtMs,
    this.parentId,
    this.extra = const {},
  });

  final String id;
  final String? parentId;
  final NodeKind kind;
  final String title;
  final String mimeType;
  final int sizeBytes;
  final String checksumSha256;
  final List<String> tags;
  final int createdAtMs;
  final int updatedAtMs;
  final Map<String, String> extra;
}

/// A user-defined tag; may be nested via [parent].
class Tag {
  const Tag({required this.name, this.parent, this.color});

  final String name;
  final String? parent;
  final String? color;
}

/// A directed parent/child edge in the folder hierarchy.
class HierarchyLink {
  const HierarchyLink({
    required this.parentId,
    required this.childId,
    this.position = 0,
  });

  final String parentId;
  final String childId;
  final int position;
}
