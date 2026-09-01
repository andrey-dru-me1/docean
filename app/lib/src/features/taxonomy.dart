import 'domain.dart';

/// Tagging & hierarchy service (mirrors `core::taxonomy::Taxonomy`).
///
/// Purely domain logic on top of [DocumentStore]; no new crates expected.
abstract interface class Taxonomy {
  Future<void> moveNode(String node, {String? newParent});
  Future<void> tag(String doc, Iterable<Tag> tags);
  Future<void> untag(String doc, String tag);

  Future<List<String>> ancestors(String doc);
  Future<Set<String>> descendants(String doc);

  Future<List<Document>> byTag(String tag);
}
